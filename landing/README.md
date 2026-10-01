# Augment download site

This is a static Vercel landing site for the Android Augment application.

## Publish an APK release

From the workspace root, build all Android ABI variants and copy them into the
site's public downloads folder:

```powershell
.\scripts\build_android_release.ps1
```

The script runs the required command:

```powershell
flutter build apk --release --split-per-abi --dart-define=AUGMENT_API_URL=https://your-api-domain.example
```

It publishes these static files:

- `augment-arm64-v8a.apk` — recommended for modern Android phones
- `augment-armeabi-v7a.apk` — older 32-bit Android phones
- `augment-x86_64.apk` — Android emulators
- `release.json` — version, size, and SHA-256 information shown by the site

The script defaults to the deployed Augment Railway API. Override it with
`-ApiUrl 'https://your-api-domain.example'` when moving servers. It reads the
app version from `frontend/pubspec.yaml`, copies all three APKs into
`landing/public/downloads`, and rebuilds `landing/dist` with the same files.
Running plain `flutter build apk --split-per-abi` alone does not copy files
to the website or configure its API URL; use the wrapper above.

## Current Railway download page

The Node API also serves the landing page at
`https://augment-production-f590.up.railway.app/download/`.
For the next public release, run `.\scripts\build_android_release.ps1 -Publish`
from the workspace root. This uploads only APKs to the public
`augment-app-downloads` Supabase bucket, verifies their checksums, and copies
the site (without APK binaries) into `backend/src/public/download-site`.
Push those changed files to deploy the updated page. Credentials never enter
the site or GitHub. APK URLs are content-addressed so old cached downloads
cannot masquerade as the latest release.

## Optional Vercel deployment

1. Push this repository to GitHub. The repository address should be `https://github.com/kaazumiip/Augment.git`.
2. In Vercel, choose **Add New → Project**, import the GitHub repository, and set **Root Directory** to `landing`.
3. Vercel detects `landing/vercel.json`. Leave the build command as `npm run build` and output directory as `dist`.
4. APKs are intentionally excluded from GitHub. A GitHub-only deployment will
   not include the local APKs. Deploy the locally built `landing/dist` with the
   Vercel CLI, or provision release assets separately before publishing.

Do not publish an APK until it is signed with your Android release signing key.
