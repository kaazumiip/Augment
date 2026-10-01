<#
Build Augment's signed release APKs per Android ABI and publish them to the
Vercel landing site's static download directory.

Example:
  .\scripts\build_android_release.ps1 -ApiUrl 'https://api.your-domain.com'
#>
[CmdletBinding()]
param(
  [ValidatePattern('^https://')]
  [string]$ApiUrl = 'https://augment-production-f590.up.railway.app',
  [switch]$Publish
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
$flutterProject = Join-Path $workspace 'frontend'
$downloadDirectory = Join-Path $workspace 'landing\public\downloads'
$apiUrl = $ApiUrl.TrimEnd('/')

if (-not (Test-Path -LiteralPath $flutterProject)) {
  throw "Flutter project not found: $flutterProject"
}
New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null

Push-Location $flutterProject
try {
  # This is intentionally a release build. Debug APKs must never be published
  # to the public download site.
  flutter build apk --release --split-per-abi "--dart-define=AUGMENT_API_URL=$apiUrl"
  if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed.' }
} finally {
  Pop-Location
}

$apkSource = Join-Path $flutterProject 'build\app\outputs\flutter-apk'
$releaseFiles = @{
  'arm64-v8a'   = 'app-arm64-v8a-release.apk'
  'armeabi-v7a' = 'app-armeabi-v7a-release.apk'
  'x86_64'      = 'app-x86_64-release.apk'
}
$published = @{}
foreach ($abi in $releaseFiles.Keys) {
  $source = Join-Path $apkSource $releaseFiles[$abi]
  if (-not (Test-Path -LiteralPath $source)) { throw "Expected APK is missing: $source" }
  $destinationName = "augment-$abi.apk"
  $destination = Join-Path $downloadDirectory $destinationName
  Copy-Item -LiteralPath $source -Destination $destination -Force
  $file = Get-Item -LiteralPath $destination
  $published[$abi] = [ordered]@{
    file = $destinationName
    bytes = $file.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
  }
}

$pubspec = Get-Content -LiteralPath (Join-Path $flutterProject 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*([^\s+]+)(?:\+(\d+))?\s*$') {
  throw 'Could not read app version from pubspec.yaml.'
}
$appVersion = $Matches[1]
$appBuild = $Matches[2]
$manifest = [ordered]@{
  published = (Get-Date).ToUniversalTime().ToString('o')
  version = $appVersion
  build = $appBuild
  apks = $published
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $downloadDirectory 'release.json') -Encoding utf8

if ($Publish) {
  node (Join-Path $PSScriptRoot 'publish_android_downloads.cjs')
  if ($LASTEXITCODE -ne 0) { throw 'APK publication failed.' }
}

Push-Location (Join-Path $workspace 'landing')
try {
  npm run build
  if ($LASTEXITCODE -ne 0) { throw 'Landing page build failed.' }
} finally {
  Pop-Location
}

Write-Host "Published APKs to $downloadDirectory"
Write-Host 'Download website and APKs are ready in landing/dist. Deploy that folder to publish them online.'
