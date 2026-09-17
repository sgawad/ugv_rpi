# Raspberry Pi OS Trixie port: fixes and dependencies

This fork adapts `waveshareteam/ugv_rpi` (branch `refactor/debian12-2025.10.01-py3.11`)
to **Raspberry Pi OS Trixie — Debian 13, Python 3.13**, and fixes several bugs found
while getting it running. Part 1 lists what was broken and how it was fixed. Part 2
lists everything the application depends on.

Verified on:

| | |
|---|---|
| Board | Raspberry Pi 5 Model B Rev 1.1 |
| OS | Raspberry Pi OS Trixie (Debian 13), kernel 6.18.50 |
| Python | 3.13.5 |
| Camera | Raspberry Pi AI Camera (IMX500) |
| Robot | UGV Rover chassis + 2-Axis Pan-Tilt Camera Module |

---

## Part 1 — What was fixed

| Commit | Fix |
|---|---|
| `e28b700` | Trixie / Python 3.13 support: requirements, apt packages, mediapipe, audio |
| `fd586ae` | JupyterLab login token, `ipywidgets` |
| `d5043f4` | Executable bit on `scripts/jupyter_url.sh` |
| `3b57ba0` | ESP32 UART selection on Pi 5 |
| `83993cd` | CSI camera pixel format |
| `7f8b8d8` | Documented robot/module type and the single-instance rule |

### 1. Installation failed on every compiled dependency

**Symptom.** `setup.sh` died at `av==10.0.0` with a Cython error. Pinning a newer
`av` moved the failure to `dbus-python` (missing `dbus-1` headers), then
`flatbuffers==20181003210633` (a timestamp version no longer on PyPI), then
`lxml==4.9.2` (missing `libxml2` headers). Each fix exposed the next.

**Cause.** `requirements.txt` was a full `pip freeze` of a **Bookworm desktop image** —
350 lines including `thonny`, `PyQt5`, `torch`, `python-apt`, `sense-hat` and about 200
`types-*` stubs, none of which the application imports. Its exact pins were chosen for
Python 3.11 and have no `cp313` wheels, so pip fell back to building from source.

**Fix.** Replaced it with the ~20 packages the code actually imports, using lower bounds
instead of exact pins. The original is preserved as `requirements.bookworm-freeze.txt`.
The package list was derived by parsing every `import` in the repo with `ast`, not by
guessing — a first pass with `grep` missed `netifaces` and `psutil`, which appear on
comma-joined import lines.

### 2. Compiled libraries rebuilt instead of reused

**Cause.** The venv is created with `--system-site-packages`, but the old requirements
also listed numpy, OpenCV, Pillow and picamera2, so pip tried to build its own copies.

**Fix.** `setup.sh` installs those from apt and `requirements.txt` omits them entirely,
so the venv inherits Trixie-native builds. This matters beyond convenience: a pip numpy
or OpenCV alongside apt's breaks the ABI that `picamera2` is compiled against.

### 3. `ncnn` silently shadowed the system OpenCV

**Symptom.** After a successful install, `cv2.__version__` reported 5.0.0 from inside
the venv instead of apt's 4.10.0.

**Cause.** Recent `ncnn` wheels declare a dependency on `opencv-python`, so pip pulled
OpenCV 5 into the venv, where it takes precedence over the system package.

**Fix.** `setup.sh` installs ncnn with `--no-deps` in a separate step. It imports fine
without `opencv-python`.

### 4. MediaPipe killed the whole application

**Symptom.** `import mediapipe as mp` at the top of `cv_ctrl.py` aborted startup.

**Cause.** The only MediaPipe release installable on Python 3.13 is 1.0.x, which removed
the legacy `mp.solutions` API. (Confirmed by reading the wheel's central directory: it
ships `modules/` and `tasks/` only.) Versions that still have `mp.solutions` (0.10.x)
publish no `cp313` wheels.

**Fix.** The import is now optional and guarded by `hasattr(mp, 'solutions')`, so a
MediaPipe 1.x install counts as absent. **Gesture Recognition, MediaPipe Faces and Pose
are unavailable on Python 3.13**; they draw a "mediapipe unavailable" banner instead of
crashing. Every other CV mode — ncnn face detection, motion detection, line tracking,
colour recognition, MobileNet-SSD object recognition — is unaffected. On Python 3.11,
adding `mediapipe==0.10.9` restores them.

### 5. Audio logged a failed probe forever

**Symptom.** The log filled with `pactl list sinks failed: No such file or directory`.

**Cause.** `_init_mixer_backend()` polls for the USB audio device with `pactl`, which is
not installed by default on Trixie. The retry loop cannot distinguish "device not ready
yet" from "the tool does not exist".

**Fix.** `audio_ctrl.py` checks for the binary with `shutil.which()` first; if it is
missing it warns once and leaves audio disabled. `setup.sh` now installs
`pulseaudio-utils`.

### 6. Wrong UART on Pi 5 — no communication with the ESP32

**Symptom.** `base_voltage` stayed at 0 and a raw read of the port returned 0 bytes in
8 seconds, while the rest of the app ran fine.

**Cause.** Two separate problems.

- `app.py` hardcoded `/dev/ttyAMA0` for Pi 5, which **does not exist until the machine
  is rebooted** after `setup.sh` adds `dtparam=uart0=on` to `/boot/firmware/config.txt`.
- An intermediate fix that preferred `/dev/serial0` was also wrong: on Pi 5 that symlink
  points at `/dev/ttyAMA10`, the **separate debug connector** (which carries a login
  console by design), not the GPIO 14/15 UART the ESP32 is wired to.

**Fix.** `resolve_uart_port()` prefers `/dev/ttyAMA0` on Pi 5 and `/dev/serial0` on Pi 4
and earlier, logs the node it chose, and reports that `dtparam=uart0=on` needs a reboot
when the expected node is missing. **A reboot after `setup.sh` is mandatory**, not
optional. After rebooting, telemetry read `base_voltage = 11.5 V`.

### 7. Camera appeared unsupported — magenta, striped, tiled video

**Symptom.** The video stream looked like static: magenta cast, interlaced stripes,
repeated tiles. Easy to mistake for an unsupported camera model.

**Cause.** `picamera2` is configured with `format: 'XRGB8888'`, so `capture_array()`
returns **4 channels**. The array was written straight into ffmpeg's stdin, which is
opened with `-pix_fmt bgr24` — **3 bytes per pixel**. Every frame desynchronised the
pipe by a quarter of its length.

**Fix.** Convert BGRA to BGR immediately after capture, so the USB, CSI and OAK paths
all produce the 3-channel BGR frames that the OpenCV modes, the video recorder and the
ffmpeg pipe already assume. The recorder's `COLOR_BGRA2RGB` became `COLOR_BGR2RGB` to
match.

**This affects any CSI camera on this branch**, not just the AI Camera — the format is
fixed in code, not negotiated with the sensor.

### 8. JupyterLab still demanded a token

**Cause.** `autorun.sh` appended `c.NotebookApp.token = ''` to
`~/.jupyter/jupyter_notebook_config.py`. JupyterLab 4 authenticates through
`ServerApp.token` and loads `jupyter_config` / `jupyter_server_config`, so that line has
no effect. The generated token appeared only in `ugv-jupyter.log`.

**Fix.** Authentication is left **enabled**. `scripts/jupyter_url.sh` asks the running
server for its URL and prints the local and LAN forms with the token. `jupyter server
password` is documented as the alternative. `ipywidgets` was also added — 25 tutorial
notebooks import it.

### 9. Configuration and operational traps (documented, not code)

Neither of these produces an error that points at the cause; both are now in the README.

- **`module_type` must match your hardware.** `config.yaml` ships with `module_type: 1`
  (RoArm-M2). The Web UI builds its controls from that value and the app announces it to
  the ESP32 with `{"T":900,...}`. A pan-tilt robot needs `module_type: 2`, otherwise the
  HUD renders arm controls. Values: `0` none, `1` RoArm-M2, `2` PT (pan-tilt),
  `3` RoArm-M3; `main_type`: `1` RaspRover, `2` UGV Rover, `3` UGV Beast.
- **Only one `app.py` may run at a time.** A second instance cannot open the camera — the
  UI then shows *camera read failed* — and both read the same UART, producing
  `[base_ctrl.feedback_data] error: ... multiple access on port`. `./scripts/autorun.sh`
  installs a systemd user service that keeps exactly one running across reboots.

---

## Part 2 — What the application depends on

### Runtime model

Python **3.13.5** in a virtual environment at `~/ugv_rpi/ugv-env`, created with
`--system-site-packages`. Compiled and hardware-bound libraries come from **apt**;
everything pure-Python (plus three wheels that publish `cp313`/`aarch64` builds) comes
from **pip**. Mixing the two for numpy or OpenCV breaks `picamera2`.

### apt packages the venv inherits

| Package | Version tested | Imported as | Used by | Purpose |
|---|---|---|---|---|
| `python3-opencv` | 4.10.0 | `cv2` | `cv_ctrl.py` | All computer vision, frame processing, DNN inference |
| `python3-numpy` | 2.2.4 | `numpy` | `cv_ctrl.py` | Frame buffers and maths |
| `python3-picamera2` | 0.3.37 | `picamera2` | `cv_ctrl.py` | CSI camera capture (libcamera) |
| `python3-pil` | 11.1.0 | `PIL` | `cv_ctrl.py` | TrueType text overlay (CJK via `fonts-wqy-zenhei`) |
| `python3-pygame` | 2.6.1 | `pygame` | `audio_ctrl.py`, `joy_ctrl.py` | Audio mixer playback, USB gamepad |
| `python3-pyaudio` | 0.2.13 | `pyaudio` | `audio_ctrl.py` | Microphone capture |
| `python3-soundfile` | 0.13.1 | `soundfile` | `audio_ctrl.py` | Reading/writing audio files |
| `python3-pyudev` | 0.24.3 | `pyudev` | `joy_ctrl.py` | Hot-plug detection for the gamepad |
| `python3-netifaces` | 0.11.0 | `netifaces` | `os_info.py` | Interface IP addresses for the OSD |
| `python3-psutil` | 7.0.0 | `psutil` | `os_info.py` | CPU load, temperature, RAM for telemetry |
| `python3-serial` | 3.5 | `serial` | `base_ctrl.py` | UART link to the ESP32 |
| `python3-yaml` | 6.0.2 | `yaml` | everywhere | `config.yaml` |

### pip packages (direct, from `requirements.txt`)

| Package | Version tested | Purpose |
|---|---|---|
| `Flask` | 3.1.3 | Web application |
| `Flask-SocketIO` | 5.6.1 | Real-time control and telemetry channels |
| `python-socketio` | 5.17.0 | Socket.IO protocol |
| `python-engineio` | 4.14.0 | Engine.IO transport |
| `simple-websocket` | 1.1.0 | WebSocket backend for Socket.IO |
| `imutils` | 0.5.4 | OpenCV convenience helpers |
| `imageio` | 2.37.4 | MP4 video recording |
| `pyttsx3` | 2.99 | Offline text-to-speech (drives `espeak`) |
| `sherpa-onnx` | 1.13.8 | Neural TTS and speech recognition |
| `ncnn` | 1.0.20260526 | UltraFace face detection (installed `--no-deps`) |
| `depthai` | 2.30.0.0 | OAK camera support (optional hardware) |
| `jupyterlab` | 4.6.3 | Tutorial notebooks |
| `notebook` | 7.6.2 | Notebook server |
| `ipywidgets` | 8.1.9 | Interactive widgets used by 25 tutorials |

`PyYAML` and `pyserial` are listed in `requirements.txt` for completeness but are
satisfied by the apt packages above. Everything else in the venv is a transitive
dependency of the packages in this table.

### System tools and bundled binaries

| Tool | Version tested | Role |
|---|---|---|
| `ffmpeg` | 7.1.5 | Encodes raw BGR frames to H.264 and publishes them to RTSP |
| `mediamtx` | v1.13.1 | Bundled in `controllers/Mediamtx/`; RTSP and WebRTC server |
| `espeak` | 1.48 | Speech backend for `pyttsx3` |
| `pulseaudio-utils` | — | Provides `pactl`, used to select the USB audio sink/source |
| `git-lfs` | 3.6.1 | Fetches the model files (~116 MB) |
| `libcamera` | 0.7.2 | Camera stack behind `picamera2` |
| AccessPopup | 2026 | Optional WiFi hotspot fallback helper |

### Model files (Git LFS — run `git lfs pull`)

| Model | Size | Used for |
|---|---|---|
| `sherpa-onnx-vits-zh-ll/` | 130 MB (model.onnx 121 MB) | Neural text-to-speech |
| `ultraface-ncnn/RFB-320.bin` | 1.1 MB | Face detection (ncnn) |
| `mobilenet_iter_73000.caffemodel` | 23 MB | Object recognition via `cv2.dnn` (MobileNet-SSD, 20 VOC classes) |

### Services and ports

| Port | Service | Notes |
|---|---|---|
| 5000 | Flask web UI + Socket.IO | `ugv-app.service` (user unit) |
| 8554 | RTSP (mediamtx) | Started by the app |
| 8889 | WebRTC (mediamtx) | Browser video; 8189 ICE/UDP, 8000/8001 RTP |
| 8888 | JupyterLab | `ugv-jupyter.service`; token required |
| 8052 | AccessPopup web UI | Optional |
| 3000 | RoArm 3D preview | Optional, RoArm-M2/M3 only |

Both systemd units are **user** services installed by `./scripts/autorun.sh`, which also
runs `loginctl enable-linger` so they survive logout and reboot.

### Not used by this application

Worth stating explicitly, because the old `requirements.txt` listed several of these and
they cost install time and disk without being imported anywhere:

- **PyTorch** (`torch`, `torchvision`, `torchaudio`) — never imported. All inference runs
  through OpenCV's DNN module, ncnn, or ONNX Runtime inside `sherpa-onnx`.
- **TensorFlow / `tflite-runtime` / `tflite-support` / `flatbuffers`** — not imported.
- **PyAV (`av`), `aiortc`, `aioice`** — not imported; WebRTC is handled by the mediamtx
  binary, not in Python.
- **`mediapipe`** — see fix 4: unavailable on Python 3.13.
- **The camera's on-sensor AI** — the IMX500's neural accelerator is *not* used. The app
  treats it as an ordinary camera and runs its models on the Pi's CPU. Using the
  accelerator would need the `imx500-all` firmware package and picamera2's IMX500 API.
