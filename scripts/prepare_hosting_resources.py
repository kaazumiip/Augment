"""Package only existing production fonts and VPO solo-violin sample dependencies."""
import hashlib
from pathlib import Path
import re
import zipfile

root = Path(__file__).resolve().parents[1]
fonts = root / 'backend/python/soundfonts'
vpo = root / 'backend/python/resources/vpo/Virtual-Playing-Orchestra3'
patch = vpo / 'Strings/1st-violin-SOLO-PERF.sfz'
files = [(fonts / name, name) for name in (
    'Custom Classical Guitar.sf2', 'MuseScore_General.sf3',
    'Stein Grand Piano.SF2', 'Tenor Saxophone.SF2', 'Violin Real 2026.SF2')]
files.append((patch, 'vpo/' + patch.relative_to(vpo).as_posix()))
samples = set()
for match in re.finditer(r'\bsample\s*=\s*(.+?)(?=\s+\w+\s*=|\r?\n|$)', patch.read_text()):
    sample = (patch.parent / match.group(1).strip().replace('\\', '/')).resolve()
    if not sample.is_relative_to(vpo.resolve()) or not sample.is_file():
        raise ValueError('Missing or unsafe VPO sample reference')
    samples.add(sample)
files.extend((sample, 'vpo/' + sample.relative_to(vpo).as_posix()) for sample in sorted(samples))
files.extend((doc, 'vpo/' + doc.relative_to(vpo).as_posix())
             for doc in vpo.rglob('*') if doc.is_file() and
             ('license' in doc.name.lower() or doc.name.lower().startswith('readme')))
output = root / '.codex-hosting'
output.mkdir(exist_ok=True)
archive_path = output / 'production-resources.zip'
with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
    for source, name in files:
        archive.write(source, name)
digest = hashlib.sha256()
with archive_path.open('rb') as archive:
    index = 0
    while chunk := archive.read(40 * 1024 * 1024):
        digest.update(chunk)
        (output / f'resources-part-{index:02d}.bin').write_bytes(chunk)
        index += 1
(output / 'bundle-sha256.txt').write_text(digest.hexdigest())
print(f'Packaged {len(files)} files, {len(samples)} violin samples, {index} private upload parts.')
