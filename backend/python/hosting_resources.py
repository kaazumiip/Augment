"""Install a private, checksum-verified resource bundle before hosting startup."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request
import zipfile


def install_resources():
    manifest_text = os.environ.get('AUGMENT_RESOURCE_MANIFEST')
    if not manifest_text:
        return
    manifest = json.loads(manifest_text)
    destination = Path('/app/soundfonts')
    destination.mkdir(parents=True, exist_ok=True)
    marker = destination / '.resource-bundle-sha256'
    expected = manifest['sha256']
    if marker.exists() and marker.read_text().strip() == expected:
        return
    digest = hashlib.sha256()
    with tempfile.TemporaryFile() as archive:
        for url in manifest['parts']:
            if not url.startswith('https://'):
                raise ValueError('Resource download requires HTTPS')
            with urllib.request.urlopen(url, timeout=120) as response:
                while chunk := response.read(1024 * 1024):
                    archive.write(chunk)
                    digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError('Resource checksum mismatch')
        archive.seek(0)
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                target = (destination / member.filename).resolve()
                if not target.is_relative_to(destination.resolve()):
                    raise ValueError('Unsafe resource archive path')
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.open(member) as source, target.open('wb') as output:
                        while chunk := source.read(1024 * 1024):
                            output.write(chunk)
        marker.write_text(expected)
    print('Private production sound libraries installed and verified.', flush=True)


if __name__ == '__main__':
    # Never include temporary signed URLs in error output.
    try:
        install_resources()
    except Exception as error:
        raise SystemExit(f'Resource installation failed ({type(error).__name__}).')
