const releaseStatus = document.querySelector('#release-status');
const releaseVersion = document.querySelector('#release-version');
const apkLinks = [...document.querySelectorAll('[data-apk]')];

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return '';
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

async function loadRelease() {
  try {
    const response = await fetch('downloads/release.json', { cache: 'no-store' });
    if (!response.ok) throw new Error('No published release yet.');
    const release = await response.json();
    if (!release.published || !release.apks) throw new Error('No published release yet.');
    releaseVersion.textContent = `v${release.version}`;
    releaseStatus.textContent = `Version ${release.version} · published ${new Date(release.published).toLocaleDateString()}`;
    apkLinks.forEach((link) => {
      const apk = release.apks[link.dataset.apk];
      if (!apk?.file) {
        link.setAttribute('aria-disabled', 'true');
        return;
      }
      link.removeAttribute('aria-disabled');
      link.href = `${apk.url || `downloads/${apk.file}`}?v=${encodeURIComponent(apk.sha256 || release.published)}`;
      const metadata = link.querySelector('small');
      metadata.textContent = `${link.dataset.apk} · ${formatBytes(apk.bytes)}`;
    });
  } catch {
    releaseStatus.textContent = 'The Android release is being prepared. Please check back shortly.';
    apkLinks.forEach((link) => link.setAttribute('aria-disabled', 'true'));
  }
}

document.querySelector('#year').textContent = new Date().getFullYear();
loadRelease();
