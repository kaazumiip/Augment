# Railway deployment preparation

This repository contains application source, not local generated songs, private
credentials, developer experiments, or third-party sample libraries.

## Node API

Create a Railway service with root directory `backend`. Its Dockerfile installs
production Node dependencies. Set variables from `backend/.env.example` privately
in Railway; do not commit actual values. Set `PYTHON_BACKEND_URL` to the Python
service address and `MAX_ACTIVE_GENERATIONS=1` for the demo.

Set `FIREBASE_SERVICE_ACCOUNT_JSON` to the private Firebase Admin JSON contents.
The existing local credential file remains supported for local development.
Mount persistent storage at `/app/data` before using payments/subscriptions:
these currently use JSON files and must not be lost during redeployment.
Use one Node replica: its generation queue is held in memory.

## Python music service — additional work required

The current Python service is NOT yet verified to deploy on Railway. It needs
Python 3.11, the dependencies in `backend/python/requirements.txt`, FFmpeg,
FluidSynth, a headless MuseScore installation, and the selected SoundFonts.
VPO playback also needs a Linux sfizz renderer and its licensed sample library.
The Windows runtime binaries are deliberately excluded.

Provision the existing SoundFonts and SFZ libraries separately after reviewing
their redistribution licenses. Preserve their existing names and sample paths.
Do not substitute sounds silently. Model downloads and generated files also
require adequate disk space. A Linux container build and a full generation
smoke test are still required before calling this hosted deployment ready.

The Python development server currently listens on port 5000. Configure the
service networking accordingly; a production WSGI setup is recommended.

## Android release and download website

Build with the public Node API HTTPS origin:

```powershell
.\scripts\build_android_release.ps1 -ApiUrl 'https://YOUR-NODE-API'
```

The `landing` folder contains the download website. APK binaries are excluded
from Git. Publish them through release assets or provision them separately.
Review Android production signing before a public release: the current build
configuration uses debug signing.

## Security

The testing redeem code and simulated card flows need review before a public,
real-money launch. Keep this demo restricted to testers. Never publish server
keys, user/payment JSON data, or private audio uploads.
