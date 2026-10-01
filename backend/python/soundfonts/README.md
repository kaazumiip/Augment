# General MIDI SoundFont

Use the MuseScore General soundfont instead of the old Android Framework
SourceForge project. Download `MuseScore_General.sf3` from:

https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General.sf3

Place the downloaded file in this folder:

`backend/python/soundfonts/MuseScore_General.sf3`

The backend also accepts `FluidR3_GM.sf2`, or any `.sf2` / `.sf3` file whose
full path is set in the `SOUNDFONT_PATH` environment variable.

FluidSynth itself must also be installed on Windows and available to the Python
environment. The backend renders each part with its General MIDI program, for
example violin for a Violin part and acoustic guitar for a Guitar or Ukulele
part.
