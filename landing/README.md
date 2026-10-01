# Augment download site

This is a static Vercel landing site for the Android Augment application.

## Publish an APK release

From the workspace root, build all Android ABI variants and copy them into the
site's public downloads folder:

```powershell
.\scripts\build_android_release.ps1 -ApiUrl 'https://your-api-domain.example'
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

The API URL is required because release builds cannot use the development
`127.0.0.1` backend.

## Deploy to Vercel

1. Push this repository to GitHub. The repository address should be `https://github.com/kaazumiip/Augment.git`.
2. In Vercel, choose **Add New → Project**, import the GitHub repository, and set **Root Directory** to `landing`.
3. Vercel detects `landing/vercel.json`. Leave the build command as `npm run build` and output directory as `dist`.
4. Deploy. Every later GitHub push redeploys the website.

Do not publish an APK until it is signed with your Android release signing key.
