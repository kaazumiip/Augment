import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'choose_tuner_instrument_page.dart';
import 'tuner_audio.dart';
import 'tuner_pitch.dart';

class TunerPage extends StatefulWidget {
  const TunerPage({super.key, required this.instrument, this.audioSource});

  final TunerInstrument instrument;
  // Ownership transfers to the page, including disposal.
  final TunerAudioSource? audioSource;

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with WidgetsBindingObserver {
  late final TunerAudioSource _audio;
  StreamSubscription<double?>? _pitchSubscription;
  Timer? _silenceTimer;
  int _request = 0;
  bool _foreground = true;
  bool _starting = false;
  String? _audioError;
  bool _automatic = true;
  int _selectedStringIndex = 0;
  String _currentNote = '--';
  double _centsDeviation = 0;
  bool _isTuned = false;
  bool _isListening = false;
  bool _outOfRange = false;
  bool _showWrittenPitch = false;
  int? _detectedConcertMidi;
  double? _detectedHz;
  final List<double> _recentPitches = [];
  int? _candidateStringIndex;
  int _candidateStringFrames = 0;
  double? _smoothedCents;

  @override
  void initState() {
    super.initState();
    _clearReading();
    WidgetsBinding.instance.addObserver(this);
    _audio = widget.audioSource ?? MicrophoneTunerAudio();
    _pitchSubscription = _audio.pitches.listen((hz) {
      if (mounted && _foreground && _isListening && hz != null) {
        _applyDetectedPitch(hz);
      }
    }, onError: (Object error) {
      if (mounted && _foreground) _setAudioError(error);
    });
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (_foreground) unawaited(_startListening());
  }

  void _clearReading() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _detectedHz = null;
    _detectedConcertMidi = null;
    _centsDeviation = 0;
    _isTuned = false;
    _outOfRange = false;
    _smoothedCents = null;
    _recentPitches.clear();
    _candidateStringIndex = null;
    _candidateStringFrames = 0;
    final strings = widget.instrument.strings;
    _currentNote = widget.instrument.isChromatic
        ? '--'
        : '${strings[_selectedStringIndex]['note']}${strings[_selectedStringIndex]['octave']}';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A permission prompt temporarily makes the app inactive. Let that request
    // finish, but always cancel if the app actually leaves the foreground.
    if (state == AppLifecycleState.inactive && _starting) return;
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      unawaited(_startListening());
    } else {
      ++_request;
      setState(() {
        _starting = false;
        _isListening = false;
        _clearReading();
      });
      unawaited(_stopAudio());
    }
  }

  Future<void> _startListening() async {
    if (!mounted || !_foreground || _starting || _isListening) return;
    final request = ++_request;
    setState(() {
      _starting = true;
      _audioError = null;
      _clearReading();
    });
    try {
      await _audio.start();
      if (!mounted || !_foreground || request != _request) return;
      setState(() {
        _starting = false;
        _isListening = true;
      });
    } catch (error) {
      if (mounted && request == _request) _setAudioError(error);
    }
  }

  void _setAudioError(Object error) {
    ++_request;
    setState(() {
      _starting = false;
      _isListening = false;
      _clearReading();
      _audioError = error is TunerAudioException
          ? error.message
          : error is MissingPluginException
              ? 'Live tuning is unavailable in this build.'
              : 'Could not use the microphone. Check microphone access and retry.';
    });
    unawaited(_stopAudio());
  }

  Future<void> _stopAudio() async {
    try {
      await _audio.stop();
    } catch (error) {
      if (mounted && !_isListening && !_starting) {
        setState(() {
          _audioError ??= 'Could not release the microphone. Please retry.';
        });
      }
      debugPrint('Tuner microphone stop failed: $error');
    }
  }

  @override
  void dispose() {
    ++_request;
    WidgetsBinding.instance.removeObserver(this);
    _silenceTimer?.cancel();
    unawaited(_pitchSubscription?.cancel());
    unawaited(_stopAudio());
    unawaited(_audio.dispose().catchError((Object error) {
      debugPrint('Tuner microphone disposal failed: $error');
    }));
    super.dispose();
  }

  void _applyDetectedPitch(double hz) {
    if (!hz.isFinite || hz <= 0) return;
    if (!widget.instrument.isChromatic) {
      final strings = widget.instrument.strings;
      final minFreq =
          (strings.map((s) => s['freq'] as num).reduce(math.min)).toDouble();
      final maxFreq =
          (strings.map((s) => s['freq'] as num).reduce(math.max)).toDouble();
      if (hz < minFreq * 0.65 || hz > maxFreq * 2.3) {
        return;
      }
    }
    _silenceTimer?.cancel();
    _silenceTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(_clearReading);
    });
    final stabilizedHz = _stabilizePitch(hz);
    if (stabilizedHz == null) return;

    if (widget.instrument.isChromatic) {
      final pitch = chromaticPitchFor(
        stabilizedHz,
        minMidi: widget.instrument.minMidi,
        maxMidi: widget.instrument.maxMidi,
      );
      if (pitch == null) {
        setState(() {
          _detectedHz = stabilizedHz;
          _detectedConcertMidi = null;
          _currentNote = '--';
          _centsDeviation = 0;
          _isTuned = false;
          _outOfRange = true;
          _smoothedCents = null;
        });
        return;
      }
      if (_detectedConcertMidi != pitch.midi) {
        _smoothedCents = null;
        _isTuned = false;
      }
      final displayedCents = _smoothCents(pitch.cents);
      setState(() {
        _detectedConcertMidi = pitch.midi;
        _currentNote = _chromaticNoteName(pitch.midi);
        _selectedStringIndex = pitch.midi - widget.instrument.minMidi;
        _detectedHz = stabilizedHz;
        _centsDeviation = displayedCents.clamp(-50.0, 50.0);
        _isTuned = _tunedWithHysteresis(displayedCents);
        _outOfRange = false;
      });
      return;
    }
    final strings = widget.instrument.strings;
    var bestIndex = _selectedStringIndex;
    var bestCents = double.infinity;
    if (!_automatic) {
      _candidateStringIndex = null;
      _candidateStringFrames = 0;
      final target = (strings[_selectedStringIndex]['freq'] as num).toDouble();
      final cents = 1200 * math.log(stabilizedHz / target) / math.ln2;
      final octaveCents =
          1200 * math.log(stabilizedHz / (target * 2)) / math.ln2;
      // In manual mode, filter out sounds outside string's +/- 6.5 semitone range and harmonic
      if (cents.abs() > 650 && octaveCents.abs() > 250) {
        return;
      }
      bestCents = cents;
      bestIndex = _selectedStringIndex;
    } else {
      for (var index = 0; index < strings.length; index++) {
        final target = (strings[index]['freq'] as num).toDouble();
        final cents = 1200 * math.log(stabilizedHz / target) / math.ln2;
        if (cents.abs() < bestCents.abs()) {
          bestCents = cents;
          bestIndex = index;
        }
      }
      // Require several matching readings before changing the selected string.
      // This stops a noisy microphone from bouncing between nearby targets.
      if (bestIndex != _selectedStringIndex && bestCents.abs() <= 180) {
        if (_candidateStringIndex == bestIndex) {
          _candidateStringFrames++;
        } else {
          _candidateStringIndex = bestIndex;
          _candidateStringFrames = 1;
        }
        if (_candidateStringFrames < 4) {
          bestIndex = _selectedStringIndex;
          final target = (strings[bestIndex]['freq'] as num).toDouble();
          bestCents = 1200 * math.log(stabilizedHz / target) / math.ln2;
        } else {
          _candidateStringIndex = null;
          _candidateStringFrames = 0;
        }
      } else if (bestIndex == _selectedStringIndex) {
        _candidateStringIndex = null;
        _candidateStringFrames = 0;
      } else {
        // If the sound is too far from every open string, retain the string the
        // player selected and show whether it needs tightening or loosening.
        _candidateStringIndex = null;
        _candidateStringFrames = 0;
        final target =
            (strings[_selectedStringIndex]['freq'] as num).toDouble();
        bestCents = 1200 * math.log(stabilizedHz / target) / math.ln2;
        bestIndex = _selectedStringIndex;
      }
    }
    if (bestIndex != _selectedStringIndex) {
      _smoothedCents = null;
      _isTuned = false;
    }
    final displayedCents = _smoothCents(bestCents);
    setState(() {
      _selectedStringIndex = bestIndex;
      _currentNote =
          '${strings[bestIndex]['note']}${strings[bestIndex]['octave']}';
      _detectedHz = stabilizedHz;
      _centsDeviation = displayedCents.clamp(-50.0, 50.0);
      _isTuned = _tunedWithHysteresis(displayedCents);
      _outOfRange = false;
    });
  }

  String _chromaticNoteName(int concertMidi) => midiNoteName(
        concertMidi,
        preferFlats: widget.instrument.preferFlats,
        transpositionSemitones:
            _showWrittenPitch ? widget.instrument.writtenPitchOffset : 0,
      );

  void _setWrittenPitch(bool written) {
    setState(() {
      _showWrittenPitch = written;
      final midi = _detectedConcertMidi;
      if (midi != null) _currentNote = _chromaticNoteName(midi);
    });
  }

  double? _stabilizePitch(double hz) {
    _recentPitches.add(hz);
    if (_recentPitches.length > 7) _recentPitches.removeAt(0);
    if (_recentPitches.length < 3) return null;

    final sorted = [..._recentPitches]..sort();
    return sorted[sorted.length ~/ 2];
  }

  double _smoothCents(double cents) {
    final previous = _smoothedCents;
    _smoothedCents =
        previous == null ? cents : previous + (cents - previous) * .28;
    return _smoothedCents!;
  }

  bool _tunedWithHysteresis(double cents) {
    // Enter the in-tune state within 4 cents, then stay there until the note
    // drifts more than 7 cents. This avoids a flickering green confirmation.
    return cents.abs() <= (_isTuned ? 7 : 4);
  }

  void _selectString(int index) {
    if (index < 0 || index >= widget.instrument.strings.length) return;
    setState(() {
      _automatic = false;
      _selectedStringIndex = index;
      _clearReading();
    });
  }

  String get _status {
    if (_audioError != null) return _audioError!;
    if (_starting) return 'Opening microphone...';
    if (!_foreground) return 'Microphone paused';
    if (!_isListening) return 'Microphone is off';
    if (_outOfRange) {
      return 'Play a note within the ${widget.instrument.name} range';
    }
    if (_detectedHz == null) {
      return widget.instrument.isChromatic
          ? 'Listening... Play one note'
          : _automatic
              ? 'Listening... Play one string'
              : 'Listening... Play $_currentNote';
    }
    final frequency = '${_detectedHz!.toStringAsFixed(1)} Hz';
    if (_isTuned) return '$frequency \u00b7 IN TUNE';
    final direction = _centsDeviation < 0 ? 'TOO LOW' : 'TOO HIGH';
    final instruction = widget.instrument.isChromatic
        ? ''
        : _centsDeviation < 0
            ? ' \u00b7 Tighten'
            : ' \u00b7 Loosen';
    return '$frequency \u00b7 $direction$instruction';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final landscape = constraints.maxWidth > constraints.maxHeight &&
              constraints.maxWidth >= 600;
          final panel = _buildPanel(context);
          if (landscape) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: SingleChildScrollView(child: panel)),
              Expanded(
                child: SingleChildScrollView(
                  child: _buildArtwork(math.max(280, constraints.maxHeight)),
                ),
              ),
            ]);
          }
          final isWidePortrait = constraints.maxWidth >= 500 &&
              (constraints.maxHeight / constraints.maxWidth) < 1.6;
          final artworkHeight = isWidePortrait
              ? (constraints.maxHeight - 440).clamp(320.0, 560.0)
              : (constraints.maxHeight - 400).clamp(240.0, 520.0);
          return SingleChildScrollView(
            child: Column(children: [
              panel,
              SizedBox(height: isWidePortrait ? 44 : 12),
              _buildArtwork(artworkHeight),
            ]),
          );
        }),
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    const red = Color(0xFFBA0007);
    final muted = AppPalette.muted(context);
    return Padding(
      key: const ValueKey('tuner-panel'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(children: [
        Row(children: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.maybePop(context),
            icon:
                Icon(Icons.arrow_back_ios_new, color: AppPalette.text(context)),
          ),
          const Spacer(),
          Icon(
            _isListening ? Icons.mic : Icons.mic_off,
            semanticLabel: _isListening ? 'Microphone on' : 'Microphone off',
            color: _isListening ? red : muted,
            size: 20,
          ),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            Text(widget.instrument.name,
                style: const TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: red,
                )),
            Text(widget.instrument.subtitle,
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: muted,
                )),
          ]),
        ),
        const SizedBox(height: 10),
        if (!widget.instrument.isChromatic)
          Wrap(spacing: 8, children: [
            _modeChip('Auto', _automatic, () {
              setState(() {
                _automatic = true;
                _clearReading();
              });
            }),
            _modeChip('Manual', !_automatic, () {
              setState(() {
                _automatic = false;
                _clearReading();
              });
            }),
          ])
        else if (widget.instrument.writtenPitchOffset != 0)
          Wrap(spacing: 8, children: [
            _modeChip(
                'Concert', !_showWrittenPitch, () => _setWrittenPitch(false)),
            _modeChip(
                'Written', _showWrittenPitch, () => _setWrittenPitch(true)),
          ])
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Concert pitch', style: TextStyle(color: muted)),
          ),
        const SizedBox(height: 4),
        Semantics(
          label: 'Tuning target $_currentNote',
          child: ExcludeSemantics(
              child: Text(
            _currentNote,
            key: const ValueKey('tuner-note'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Instrument Sans',
              fontSize: 76,
              fontWeight: FontWeight.w900,
              height: 1.1,
              color: _isTuned ? const Color(0xFF23834D) : red,
            ),
          )),
        ),
        if (!widget.instrument.isChromatic)
          Text(
            _stringTargetLabel,
            key: const ValueKey('tuner-string-target'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Instrument Sans',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: muted,
            ),
          ),
        const SizedBox(height: 8),
        Text(
          _status,
          key: const ValueKey('tuner-status'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Instrument Sans',
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
        if (_audioError != null)
          TextButton.icon(
            onPressed: _starting ? null : _startListening,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
            style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
          ),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('TOO LOW', style: TextStyle(fontSize: 10, color: muted)),
          Text('TOO HIGH', style: TextStyle(fontSize: 10, color: muted)),
        ]),
        Semantics(
          label: _detectedHz == null
              ? 'Waiting for pitch'
              : '${_centsDeviation.abs().toStringAsFixed(0)} cents ${_centsDeviation < 0 ? 'flat' : 'sharp'}',
          child: SizedBox(
            key: const ValueKey('tuner-meter'),
            height: 44,
            width: double.infinity,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: _centsDeviation),
              duration: const Duration(milliseconds: 180),
              builder: (context, cents, _) => CustomPaint(
                painter: _TuningMeterPainter(
                  centsDeviation: cents,
                  isTuned: _isTuned,
                  dark: AppPalette.isDark(context),
                ),
              ),
            ),
          ),
        ),
        // Reserve space so confirmation never shifts the artwork under a tap.
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: _isTuned
              ? Semantics(
                  liveRegion: true,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF23834D),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('$_currentNote in tune',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700)),
                  ))
              : Text(
                  widget.instrument.isChromatic
                      ? 'A4 = 440 Hz'
                      : _automatic
                          ? 'Tap a string to lock its target'
                          : 'Target locked \u00b7 $_currentNote',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: muted),
                ),
        ),
      ]),
    );
  }

  Widget _modeChip(String label, bool selected, VoidCallback onTap) =>
      ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        selectedColor: const Color(0xFFBA0007),
        backgroundColor: AppPalette.surface(context),
        showCheckmark: false,
        labelStyle: TextStyle(
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : AppPalette.text(context),
        ),
      );

  String get _stringTargetLabel => _stringTargetLabelFor(_selectedStringIndex);

  String _stringTargetLabelFor(int index) {
    final strings = widget.instrument.strings;
    if (index < 0 || index >= strings.length) return '';
    final note = '${strings[index]['note']}${strings[index]['octave']}';
    final ordinal = strings.length - index;
    final suffix = ordinal == 1
        ? 'st'
        : ordinal == 2
            ? 'nd'
            : ordinal == 3
                ? 'rd'
                : 'th';
    final isUkulele = widget.instrument.name.toLowerCase() == 'ukulele';
    // Standard ukulele tuning is re-entrant: its fourth string is high G,
    // even though it appears first in the G-C-E-A string list.
    final position = isUkulele
        ? index == 0
            ? 'high '
            : ''
        : index == 0
            ? 'low '
            : index == strings.length - 1
                ? 'high '
                : '';
    return '$ordinal$suffix string · $position$note';
  }

  Offset _getPegScreenPosition(
    int index,
    double width,
    double height,
    String instrumentName,
  ) {
    final nameKey = instrumentName.toLowerCase().contains('guitar') &&
            instrumentName.toLowerCase().contains('electric')
        ? 'electric guitar'
        : instrumentName.toLowerCase();
    final config = _headstockConfigs[nameKey];
    if (config == null || index < 0 || index >= config.pegs.length) {
      final isLeft = index < 3;
      final row = isLeft ? (2 - index) : (index - 3);
      return Offset(isLeft ? 50 : width - 50, height * (0.16 + 0.17 * row));
    }

    final peg = config.pegs[index];
    final artworkWidth = math.max(1.0, width - 104.0);
    final artworkHeight = height;
    final artLeft = (width - artworkWidth) / 2.0;

    final imgAR = config.assetWidth / config.assetHeight;
    final containerAR = artworkWidth / artworkHeight;
    final fitW = containerAR < imgAR ? artworkWidth : artworkHeight * imgAR;
    final fitH = containerAR < imgAR ? artworkWidth / imgAR : artworkHeight;
    final unscaledLeft = (artworkWidth - fitW) / 2.0;
    final unscaledTop = artworkHeight - fitH;

    final rawPegX = unscaledLeft + peg.normX * fitW;
    final rawPegY = unscaledTop + peg.normY * fitH;

    const scale = 1.12;
    final scaledPegX =
        (artworkWidth / 2.0) + (rawPegX - artworkWidth / 2.0) * scale;
    final scaledPegY = artworkHeight + (rawPegY - artworkHeight) * scale;

    return Offset(artLeft + scaledPegX, scaledPegY);
  }

  Offset _getStringButtonPosition(
    int index,
    int totalStrings,
    double width,
    double height,
    String instrumentName,
  ) {
    final pegPos = _getPegScreenPosition(index, width, height, instrumentName);
    final name = instrumentName.toLowerCase();
    final isOneSidedBass = name == 'bass';
    final leftCount = (totalStrings + 1) ~/ 2;
    final isLeft = isOneSidedBass || index < leftCount;
    final double left = isLeft ? 8.0 : (width - 48.0 - 8.0);
    final double top = (pegPos.dy - 24.0).clamp(8.0, height - 56.0);

    return Offset(left, top);
  }

  Widget _buildArtwork(double height) {
    final instrument = widget.instrument;
    final strings = instrument.strings;
    return SizedBox(
      key: const ValueKey('tuner-artwork'),
      height: height,
      width: double.infinity,
      child: ClipRect(child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final diameter = math.min(width * .80, height * .84);

        Offset? selectedButtonPos;
        if (!instrument.isChromatic &&
            _selectedStringIndex >= 0 &&
            _selectedStringIndex < strings.length) {
          selectedButtonPos = _getStringButtonPosition(
            _selectedStringIndex,
            strings.length,
            width,
            height,
            instrument.name,
          );
        }

        return Stack(alignment: Alignment.center, children: [
          Positioned(
              top: height * .08,
              child: Container(
                width: diameter,
                height: diameter,
                decoration: const BoxDecoration(
                    color: Color(0xFFBA0007), shape: BoxShape.circle),
              )),
          Positioned.fill(
              child: ExcludeSemantics(
                  child: Center(
            child: _TunerInstrumentArtwork(
              instrumentName: instrument.name,
              width: math.max(1, width - 104),
              height: height,
              isChromatic: instrument.isChromatic,
              selectedStringIndex: _selectedStringIndex,
            ),
          ))),
          if (!instrument.isChromatic) ...[
            // Glowing Peg Highlight Overlay & Pointer to Tuning Key
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TunerPegOverlayPainter(
                    instrumentName: instrument.name,
                    selectedIndex: _selectedStringIndex,
                    buttonPosition: selectedButtonPos,
                    isTuned: _isTuned,
                    isDark: AppPalette.isDark(context),
                  ),
                ),
              ),
            ),
            for (var index = 0; index < strings.length; index++) ...[
              Builder(builder: (context) {
                final pos = _getStringButtonPosition(
                  index,
                  strings.length,
                  width,
                  height,
                  instrument.name,
                );
                return Positioned(
                  left: pos.dx,
                  top: pos.dy,
                  child: _stringButton(index),
                );
              }),
            ],
          ],
        ]);
      })),
    );
  }

  Widget _stringButton(int index) {
    final string = widget.instrument.strings[index];
    final label = '${string['note']}${string['octave']}';
    final selected = _selectedStringIndex == index;
    const red = Color(0xFFBA0007);
    const green = Color(0xFF23834D);
    final isDark = AppPalette.isDark(context);

    final activeBg = _isTuned ? green : Colors.white;
    final activeFg = _isTuned ? Colors.white : const Color(0xFF1D1D1F);
    final inactiveBg = isDark
        ? const Color(0xFF242529).withValues(alpha: 0.90)
        : Colors.white.withValues(alpha: 0.92);
    final inactiveFg = isDark ? Colors.white70 : const Color(0xFF333333);
    final borderColor = selected
        ? (_isTuned ? green : red)
        : (isDark ? const Color(0xFF42444A) : const Color(0xFFD4D4D8));

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: selected
            ? [
                BoxShadow(
                  color: (_isTuned ? green : red).withValues(alpha: 0.45),
                  blurRadius: 10,
                  spreadRadius: 1.5,
                )
              ]
            : null,
      ),
      child: OutlinedButton(
        onPressed: () => _selectString(index),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.all(4),
          shape: const CircleBorder(),
          side: BorderSide(color: borderColor, width: selected ? 2.5 : 1.5),
          foregroundColor: selected ? activeFg : inactiveFg,
          backgroundColor: selected ? activeBg : inactiveBg,
          elevation: selected ? 4 : 0,
        ),
        child: Semantics(
          label: 'Lock ${_stringTargetLabelFor(index).toLowerCase()} target',
          selected: selected,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Instrument Sans',
              fontSize: 13,
              fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _PegCoordinate {
  const _PegCoordinate(
    this.normX,
    this.normY, {
    this.width = 38,
    this.height = 24,
    this.radius = 12,
    this.isRight = false,
  });
  final double normX;
  final double normY;
  final double width;
  final double height;
  final double radius;
  final bool isRight;
}

class _HeadstockConfig {
  const _HeadstockConfig({
    required this.assetWidth,
    required this.assetHeight,
    required this.pegs,
  });

  final double assetWidth;
  final double assetHeight;
  final List<_PegCoordinate> pegs;
}

const Map<String, _HeadstockConfig> _headstockConfigs = {
  'guitar': _HeadstockConfig(
    assetWidth: 423,
    assetHeight: 640,
    pegs: [
      _PegCoordinate(88 / 423, 260 / 640, width: 38, height: 24, radius: 12, isRight: false), // E2 (bottom-left)
      _PegCoordinate(92 / 423, 180 / 640, width: 38, height: 24, radius: 12, isRight: false), // A2 (middle-left)
      _PegCoordinate(88 / 423, 98 / 640, width: 38, height: 24, radius: 12, isRight: false),  // D3 (top-left)
      _PegCoordinate(312 / 423, 98 / 640, width: 38, height: 24, radius: 12, isRight: true),  // G3 (top-right)
      _PegCoordinate(312 / 423, 178 / 640, width: 38, height: 24, radius: 12, isRight: true), // B3 (middle-right)
      _PegCoordinate(312 / 423, 258 / 640, width: 38, height: 24, radius: 12, isRight: true), // E4 (bottom-right)
    ],
  ),
  'electric guitar': _HeadstockConfig(
    assetWidth: 1024,
    assetHeight: 1536,
    pegs: [
      _PegCoordinate(225 / 1024, 885 / 1536, width: 36, height: 26, radius: 8, isRight: false), // E2 (bottom-left)
      _PegCoordinate(225 / 1024, 720 / 1536, width: 36, height: 26, radius: 8, isRight: false), // A2 (middle-left)
      _PegCoordinate(225 / 1024, 555 / 1536, width: 36, height: 26, radius: 8, isRight: false), // D3 (top-left)
      _PegCoordinate(795 / 1024, 555 / 1536, width: 36, height: 26, radius: 8, isRight: true),  // G3 (top-right)
      _PegCoordinate(795 / 1024, 720 / 1536, width: 36, height: 26, radius: 8, isRight: true),  // B3 (middle-right)
      _PegCoordinate(795 / 1024, 885 / 1536, width: 36, height: 26, radius: 8, isRight: true),  // E4 (bottom-right)
    ],
  ),
  'bass': _HeadstockConfig(
    assetWidth: 1134,
    assetHeight: 1387,
    pegs: [
      _PegCoordinate(265 / 1134, 870 / 1387, width: 44, height: 32, radius: 16, isRight: false), // E1 (bottom)
      _PegCoordinate(305 / 1134, 640 / 1387, width: 44, height: 32, radius: 16, isRight: false), // A1 (2nd)
      _PegCoordinate(345 / 1134, 430 / 1387, width: 44, height: 32, radius: 16, isRight: false), // D2 (3rd)
      _PegCoordinate(390 / 1134, 230 / 1387, width: 44, height: 32, radius: 16, isRight: false), // G2 (top)
    ],
  ),
  'ukulele': _HeadstockConfig(
    assetWidth: 1113,
    assetHeight: 1414,
    pegs: [
      _PegCoordinate(220 / 1113, 350 / 1414, width: 36, height: 26, radius: 13, isRight: false), // G4 (top-left)
      _PegCoordinate(220 / 1113, 640 / 1414, width: 36, height: 26, radius: 13, isRight: false), // C4 (bottom-left)
      _PegCoordinate(890 / 1113, 350 / 1414, width: 36, height: 26, radius: 13, isRight: true),  // E4 (top-right)
      _PegCoordinate(890 / 1113, 640 / 1414, width: 36, height: 26, radius: 13, isRight: true),  // A4 (bottom-right)
    ],
  ),
  'violin': _HeadstockConfig(
    assetWidth: 1024,
    assetHeight: 1536,
    pegs: [
      _PegCoordinate(180 / 1024, 840 / 1536, width: 32, height: 22, radius: 11, isRight: false), // G3 (lower-left)
      _PegCoordinate(200 / 1024, 540 / 1536, width: 32, height: 22, radius: 11, isRight: false), // D4 (upper-left)
      _PegCoordinate(810 / 1024, 430 / 1536, width: 32, height: 22, radius: 11, isRight: true),  // A4 (upper-right)
      _PegCoordinate(820 / 1024, 720 / 1536, width: 32, height: 22, radius: 11, isRight: true),  // E5 (lower-right)
    ],
  ),
  'cello': _HeadstockConfig(
    assetWidth: 736,
    assetHeight: 736,
    pegs: [
      _PegCoordinate(330 / 736, 105 / 736, width: 22, height: 16, radius: 8, isRight: false), // C2 (lower-left)
      _PegCoordinate(330 / 736, 65 / 736, width: 22, height: 16, radius: 8, isRight: false),  // G2 (upper-left)
      _PegCoordinate(385 / 736, 65 / 736, width: 22, height: 16, radius: 8, isRight: true),   // D3 (upper-right)
      _PegCoordinate(385 / 736, 95 / 736, width: 22, height: 16, radius: 8, isRight: true),   // A3 (lower-right)
    ],
  ),
};

class _TunerPegOverlayPainter extends CustomPainter {
  const _TunerPegOverlayPainter({
    required this.instrumentName,
    required this.selectedIndex,
    required this.buttonPosition,
    required this.isTuned,
    required this.isDark,
  });

  final String instrumentName;
  final int selectedIndex;
  final Offset? buttonPosition;
  final bool isTuned;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final nameKey = instrumentName.toLowerCase().contains('guitar') &&
            instrumentName.toLowerCase().contains('electric')
        ? 'electric guitar'
        : instrumentName.toLowerCase();
    final config = _headstockConfigs[nameKey];
    if (config == null ||
        selectedIndex < 0 ||
        selectedIndex >= config.pegs.length) {
      return;
    }

    final peg = config.pegs[selectedIndex];
    final artworkWidth = math.max(1.0, size.width - 104.0);
    final artworkHeight = size.height;
    final artLeft = (size.width - artworkWidth) / 2.0;

    final imgAR = config.assetWidth / config.assetHeight;
    final containerAR = artworkWidth / artworkHeight;
    final fitW = containerAR < imgAR ? artworkWidth : artworkHeight * imgAR;
    final fitH = containerAR < imgAR ? artworkWidth / imgAR : artworkHeight;
    final unscaledLeft = (artworkWidth - fitW) / 2.0;
    final unscaledTop = artworkHeight - fitH;

    final rawPegX = unscaledLeft + peg.normX * fitW;
    final rawPegY = unscaledTop + peg.normY * fitH;

    const scale = 1.12;
    final scaledPegX =
        (artworkWidth / 2.0) + (rawPegX - artworkWidth / 2.0) * scale;
    final scaledPegY = artworkHeight + (rawPegY - artworkHeight) * scale;

    final pegCenter = Offset(artLeft + scaledPegX, scaledPegY);

    final themeAccent =
        isTuned ? const Color(0xFF23834D) : const Color(0xFFBA0007);

    // 1. Pointer Line from String Button to Peg
    if (buttonPosition != null) {
      final btnCenter = buttonPosition! + const Offset(24, 24);
      final isBtnOnLeft = btnCenter.dx < size.width / 2;
      final btnEdge = btnCenter + Offset(isBtnOnLeft ? 24 : -24, 0);
      final pegEdge = Offset(
        pegCenter.dx + (isBtnOnLeft ? -peg.width / 2 : peg.width / 2),
        pegCenter.dy,
      );

      final pointerGlow = Paint()
        ..color = (isTuned ? const Color(0xFF4CAF50) : themeAccent)
            .withValues(alpha: 0.45)
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

      final pointerLine = Paint()
        ..color = isTuned ? const Color(0xFF4CAF50) : Colors.white
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final path = Path()
        ..moveTo(btnEdge.dx, btnEdge.dy)
        ..lineTo(pegEdge.dx, pegEdge.dy);

      canvas.drawPath(path, pointerGlow);
      canvas.drawPath(path, pointerLine);
      canvas.drawCircle(
          btnEdge, 3, Paint()..color = isTuned ? const Color(0xFF4CAF50) : Colors.white);
    }

    final pegRect = Rect.fromCenter(
      center: pegCenter,
      width: peg.width,
      height: peg.height,
    );
    final pegRRect = RRect.fromRectAndRadius(
      pegRect,
      Radius.circular(peg.radius),
    );

    // 2. Ambient Radial Glow Halo around the Peg
    final glowPaint = Paint()
      ..color = (isTuned ? const Color(0xFF4CAF50) : Colors.white)
          .withValues(alpha: 0.65)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawRRect(pegRRect.inflate(4), glowPaint);

    // 3. Peg Stem Connector (from knob inward to headstock)
    final isPegOnRight = peg.isRight;
    final stemCenter = Offset(
      pegCenter.dx + (isPegOnRight ? -peg.width / 2 - 4 : peg.width / 2 + 4),
      pegCenter.dy,
    );
    final stemRect = Rect.fromCenter(center: stemCenter, width: 10, height: 5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(stemRect, const Radius.circular(2)),
      Paint()
        ..color = isTuned
            ? const Color(0xFF2E7D32)
            : (isDark ? const Color(0xFFCCCCCC) : const Color(0xFF888888)),
    );

    // 4. Solid Illuminated Peg Body (GuitarTuna Style)
    final pegShader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: isTuned
          ? const [Color(0xFFA5D6A7), Color(0xFF43A047), Color(0xFF2E7D32)]
          : const [Color(0xFFFFFFFF), Color(0xFFF2F2F2), Color(0xFFDADADA)],
      stops: const [0.0, 0.55, 1.0],
    ).createShader(pegRect);
    canvas.drawRRect(pegRRect, Paint()..shader = pegShader);

    // 5. Specular Rim / Highlight on Peg
    final rimPaint = Paint()
      ..color = isTuned
          ? const Color(0xFFC8E6C9)
          : Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawRRect(pegRRect, rimPaint);

    // 6. Subtle 3D Inner Bevel Highlight
    final innerTopHighlight = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(pegCenter.dx - peg.width * 0.3, pegCenter.dy - peg.height * 0.28),
      Offset(pegCenter.dx + peg.width * 0.3, pegCenter.dy - peg.height * 0.28),
      innerTopHighlight,
    );
  }

  @override
  bool shouldRepaint(covariant _TunerPegOverlayPainter oldDelegate) =>
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.instrumentName != instrumentName ||
      oldDelegate.isTuned != isTuned ||
      oldDelegate.buttonPosition != buttonPosition ||
      oldDelegate.isDark != isDark;
}

class _TunerInstrumentArtwork extends StatelessWidget {
  const _TunerInstrumentArtwork({
    required this.instrumentName,
    required this.width,
    required this.height,
    required this.isChromatic,
    required this.selectedStringIndex,
  });

  final String instrumentName;
  final double width;
  final double height;
  final bool isChromatic;
  final int selectedStringIndex;

  @override
  Widget build(BuildContext context) {
    final assetPath = _assetFor(instrumentName);
    if (assetPath == null) {
      return SizedBox(
        width: width,
        height: height,
        child: CustomPaint(painter: _InstrumentArtworkPainter(instrumentName)),
      );
    }

    final isElectricGuitar = instrumentName.toLowerCase() == 'electric guitar';
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: Transform.scale(
              scale: isChromatic ? 1.18 : 1.12,
              alignment: Alignment.bottomCenter,
              child: Image.asset(
                assetPath,
                fit: BoxFit.contain,
                alignment: Alignment.bottomCenter,
              ),
            ),
          ),
          if (isElectricGuitar)
            IgnorePointer(
              child: CustomPaint(
                key: const ValueKey('electric-string-overlay'),
                painter: _ElectricGuitarStringPainter(
                  selectedStringIndex: selectedStringIndex,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String? _assetFor(String name) {
    final value = name.toLowerCase();
    if (value == 'guitar') return 'assets/tuner_guitar.png';
    if (value.contains('bass')) return 'assets/bass_tuner_head.png';
    if (value.contains('electric guitar')) {
      return 'assets/electric_guitar_tuner_head.png';
    }
    if (value.contains('ukulele')) return 'assets/ukulele_tuner_head.png';
    if (value.contains('violin')) return 'assets/violin_tuner_head.png';
    if (value.contains('cello')) return 'assets/cello.png';
    if (value.contains('sax')) return 'assets/saxophone.png';
    if (value.contains('trumpet')) return 'assets/trumpet.png';
    if (value.contains('flute')) return 'assets/flute.png';
    if (value.contains('clarinet')) return 'assets/Clarinet.png';
    return null;
  }
}

/// Matches the six visible strings on the electric-guitar headstock asset.
/// The selected string is highlighted directly on the fretboard rather than
/// adding a separate pointer over the instrument.
class _ElectricGuitarStringPainter extends CustomPainter {
  const _ElectricGuitarStringPainter({required this.selectedStringIndex});

  final int selectedStringIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (selectedStringIndex < 0 || selectedStringIndex > 5) return;
    // The transparent headstock artwork is 1024×1536 and is shown with
    // BoxFit.contain then a 1.12 scale aligned to the bottom.
    const artworkWidth = 1024.0;
    const artworkHeight = 1536.0;
    final baseScale =
        math.min(size.width / artworkWidth, size.height / artworkHeight);
    final scale = baseScale * 1.12;
    final left = (size.width - artworkWidth * scale) / 2;
    final top = size.height - artworkHeight * scale;
    const xAtNut = [405.0, 447.0, 480.0, 515.0, 552.0, 598.0];
    const xAtFingerboard = [402.0, 443.0, 477.0, 512.0, 551.0, 596.0];
    final path = Path()
      ..moveTo(left + xAtNut[selectedStringIndex] * scale, top + 1125 * scale)
      ..lineTo(left + xAtFingerboard[selectedStringIndex] * scale,
          top + 1518 * scale);
    final glow = Paint()
      ..color = const Color(0xFFBA0007).withValues(alpha: .52)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    final highlight = Paint()
      ..color = const Color(0xFFE83038)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, glow);
    canvas.drawPath(path, highlight);
  }

  @override
  bool shouldRepaint(covariant _ElectricGuitarStringPainter oldDelegate) =>
      oldDelegate.selectedStringIndex != selectedStringIndex;
}

class _InstrumentArtworkPainter extends CustomPainter {
  const _InstrumentArtworkPainter(this.instrumentName);
  final String instrumentName;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = Paint()..color = const Color(0xFF202020);
    final brass = Paint()..color = const Color(0xFFF5D36C);
    final light = Paint()..color = Colors.white.withValues(alpha: 0.78);
    final center = size.width / 2;

    if (instrumentName == 'Violin' || instrumentName == 'Cello') {
      final isCello = instrumentName == 'Cello';
      final bodyTop = size.height * (isCello ? .43 : .50);
      final bodyHeight = size.height * (isCello ? .43 : .34);
      final bodyWidth = size.width * (isCello ? .40 : .34);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center, bodyTop + bodyHeight * .30),
          width: bodyWidth,
          height: bodyHeight * .52,
        ),
        dark,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center, bodyTop + bodyHeight * .72),
          width: bodyWidth * .94,
          height: bodyHeight * .50,
        ),
        dark,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(center, size.height * .28),
            width: size.width * .075,
            height: size.height * .44,
          ),
          const Radius.circular(3),
        ),
        dark,
      );
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(center, bodyTop + bodyHeight * .48),
          width: bodyWidth * .11,
          height: bodyHeight * .58,
        ),
        light,
      );
      return;
    }

    if (instrumentName == 'Flute' || instrumentName == 'Clarinet') {
      final paint = instrumentName == 'Flute' ? light : dark;
      canvas.save();
      canvas.translate(center, size.height * .55);
      canvas.rotate(-.18);
      canvas.translate(-center, -size.height * .55);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(center, size.height * .55),
            width: size.width * .12,
            height: size.height * .70,
          ),
          const Radius.circular(20),
        ),
        paint,
      );
      for (var index = 0; index < 7; index++) {
        canvas.drawCircle(
          Offset(center, size.height * (.31 + index * .075)),
          size.width * .028,
          instrumentName == 'Flute' ? dark : brass,
        );
      }
      canvas.restore();
      return;
    }

    if (instrumentName == 'Trumpet') {
      canvas.save();
      canvas.translate(center, size.height * .52);
      canvas.rotate(-.18);
      canvas.translate(-center, -size.height * .52);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(center, size.height * .54),
            width: size.width * .18,
            height: size.height * .58,
          ),
          const Radius.circular(18),
        ),
        brass,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center, size.height * .24),
          width: size.width * .38,
          height: size.height * .13,
        ),
        brass,
      );
      for (var index = 0; index < 3; index++) {
        canvas.drawCircle(
            Offset(center + (index - 1) * 24, size.height * .51), 12, dark);
      }
      canvas.restore();
      return;
    }

    // Bass, electric guitar, and ukulele retain the string-instrument form,
    // with proportions that identify their different bodies.
    final compact = instrumentName == 'Ukulele';
    final bass = instrumentName == 'Bass';
    final bodyWidth = size.width *
        (compact
            ? .36
            : bass
                ? .40
                : .46);
    final bodyHeight = size.height * (compact ? .33 : .42);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center, size.height * .72),
        width: bodyWidth,
        height: bodyHeight,
      ),
      dark,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(center, size.height * .32),
          width: size.width * .09,
          height: size.height * .56,
        ),
        const Radius.circular(4),
      ),
      dark,
    );
    final stringCount = compact
        ? 4
        : bass
            ? 4
            : 6;
    for (var index = 0; index < stringCount; index++) {
      final x = center -
          bodyWidth * .18 +
          index * bodyWidth * .36 / (stringCount - 1);
      canvas.drawLine(Offset(x, size.height * .10),
          Offset(x, size.height * .88), light..strokeWidth = 1.2);
    }
  }

  @override
  bool shouldRepaint(covariant _InstrumentArtworkPainter oldDelegate) =>
      oldDelegate.instrumentName != instrumentName;
}

class _TuningMeterPainter extends CustomPainter {
  final double centsDeviation;
  final bool isTuned;
  final bool dark;

  _TuningMeterPainter({
    required this.centsDeviation,
    required this.isTuned,
    required this.dark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final width = size.width;

    // Draw shadow under the line
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: dark ? 0.42 : 0.15)
      ..strokeWidth = 4
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    canvas.drawLine(
      Offset(20, center.dy + 2),
      Offset(width - 20, center.dy + 2),
      shadowPaint,
    );

    // Draw the main horizontal line
    final linePaint = Paint()
      ..color = dark ? const Color(0xFF777777) : Colors.grey.shade400
      ..strokeWidth = 1.5;

    canvas.drawLine(
      Offset(20, center.dy),
      Offset(width - 20, center.dy),
      linePaint,
    );

    // Draw tick marks
    final majorTickPaint = Paint()
      ..color = dark ? const Color(0xFFAAAAAA) : Colors.grey.shade500
      ..strokeWidth = 1.5;

    final minorTickPaint = Paint()
      ..color = dark ? const Color(0xFF777777) : Colors.grey.shade400
      ..strokeWidth = 1;

    for (double i = -50; i <= 50; i += 5) {
      final x = center.dx + (i / 50) * (width / 2 - 30);
      final isMajor = i.abs() % 10 == 0;
      final tickHeight = isMajor ? 10.0 : 5.0;

      canvas.drawLine(
        Offset(x, center.dy - tickHeight / 2),
        Offset(x, center.dy + tickHeight / 2),
        isMajor ? majorTickPaint : minorTickPaint,
      );
    }

    // Draw center dot
    final centerDotPaint = Paint()
      ..color = dark ? const Color(0xFFD0D0D0) : Colors.grey.shade600
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      Offset(center.dx, center.dy),
      3,
      centerDotPaint,
    );

    // Draw needle
    final needleX = center.dx + (centsDeviation / 50) * (width / 2 - 30);
    final needlePaint = Paint()
      ..color = isTuned ? const Color(0xFF4CAF50) : const Color(0xFFBA0007)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(needleX, center.dy - 12),
      Offset(needleX, center.dy + 12),
      needlePaint,
    );

    // Draw flat symbol (b)
    final flatPainter = TextPainter(
      text: TextSpan(
        text: 'b',
        style: TextStyle(
          fontFamily: 'Instrument Sans',
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: dark ? Colors.white70 : Colors.black45,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    flatPainter.paint(canvas, Offset(2, center.dy - 8));

    // Draw sharp symbol (#)
    final sharpPainter = TextPainter(
      text: TextSpan(
        text: '#',
        style: TextStyle(
          fontFamily: 'Instrument Sans',
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: dark ? Colors.white70 : Colors.black45,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    sharpPainter.paint(canvas, Offset(width - 18, center.dy - 8));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
