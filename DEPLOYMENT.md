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

## Python music service — container prepared, cloud build not yet verified

Create a second Railway service from this repository with root directory
`backend/python`. Its Dockerfile uses Python 3.11, CPU PyTorch, Gunicorn,
FFmpeg, FluidSynth, headless MuseScore 3, LilyPond, and sfizz_render 1.2.3.
It uses one worker to avoid duplicated machine-learning model memory. This
container has not yet been built or smoke-tested in Railway.

Provision the existing SoundFonts and SFZ libraries separately after reviewing
their redistribution licenses. Preserve their existing names and sample paths.
Do not substitute sounds silently. Model downloads and generated files also
require adequate disk space. A Linux container build and a full generation
smoke test are still required before calling this hosted deployment ready.

Gunicorn binds to Railway's `PORT` (5000 locally by default). Set the Node
service's `PYTHON_BACKEND_URL` to `http://PYTHON-SERVICE.railway.internal:PORT`,
using the actual service name and its configured port. Do not expose Python
publicly: its routes are intended to be called through the authenticated Node API.

Mount Python persistent storage at `/app/soundfonts` and provision the existing
SoundFonts there. VPO can live on that same volume under a `vpo` subfolder;
set `AUGMENT_VIOLIN_VPO_SFZ_PATH` to the actual solo-violin SFZ location.
Keep all VPO referenced relative sample paths intact. The container does not
download private/custom sample files or change the chosen sounds automatically.

Before inviting testers: verify renderer binaries, upload sound libraries,
generate a short song, save and reopen it, and test cancellation. Check actual
memory and billing before establishing the demo's generation allowance.

## Android release and download website

Build with the public Node API HTTPS origin:

```powershell
.\scripts\build_android_release.ps1 -ApiUrl 'https://YOUR-NODE-API'
```

The `landing` folder contains the download website. APK binaries are excluded
from Git. Publish them through release assets or provision them separately.
Review Android production signing before a public release: the current build
configuration uses debug signing.

## Verification email delivery

Account verification and password verification codes use the landing project's
Vercel Function at `/api/send-verification`, then Gmail SMTP. Configure
`GMAIL_USER=evolveapporg@gmail.com` and `GMAIL_APP_PASSWORD` privately in Vercel
Production. Never expose these values through frontend variables or Git.

Railway generates and validates codes. It signs short-lived email requests
using its existing Firebase service-account RSA credential; Vercel holds only
the pinned public verification key in `landing/lib/email-relay-auth.cjs`.
Rotating that service-account key requires updating the pinned public key too.
There is no unauthenticated email-send route or automatic Resend fallback for
verification codes. Other existing transactional email paths still use Resend.

The Node health endpoint reports the delivery provider and public-key
fingerprint. Test delivery after deployment; Gmail accepting a message does not
guarantee Inbox placement. In-memory replay protection is instance-local, not a
distributed idempotency guarantee.

## Security

The testing redeem code and simulated card flows need review before a public,
real-money launch. Keep this demo restricted to testers. Never publish server
keys, user/payment JSON data, or private audio uploads.
