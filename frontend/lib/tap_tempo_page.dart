import 'package:flutter/material.dart';

import 'app_palette.dart';

class TapTempoPage extends StatefulWidget {
  final int initialBpm;
  final int initialBeats;

  const TapTempoPage({
    Key? key,
    this.initialBpm = 150,
    this.initialBeats = 4,
  }) : super(key: key);

  @override
  State<TapTempoPage> createState() => _TapTempoPageState();
}

class _TapTempoPageState extends State<TapTempoPage> {
  late int _bpm;
  late int _beats;
  bool _isPlaying = false;
  double _volume = 0.8;
  List<DateTime> _tapTimes = [];

  @override
  void initState() {
    super.initState();
    _bpm = widget.initialBpm;
    _beats = widget.initialBeats;
  }

  void _onTapTempo() {
    final now = DateTime.now();
    setState(() {
      _tapTimes.add(now);
      if (_tapTimes.length > 4) {
        _tapTimes.removeAt(0);
      }
      if (_tapTimes.length >= 2) {
        double totalDiff = 0;
        for (int i = 0; i < _tapTimes.length - 1; i++) {
          totalDiff += _tapTimes[i + 1].difference(_tapTimes[i]).inMilliseconds;
        }
        final averageDiff = totalDiff / (_tapTimes.length - 1);
        final calculatedBpm = (60000 / averageDiff).round();
        _bpm = calculatedBpm.clamp(40, 240);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const Color backgroundColor = Color(0xFFFAF5F1);
    const Color brandRed = Color(0xFFBA0007);

    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isSmallScreen ? 16.0 : 20.0,
                vertical: isSmallScreen ? 10.0 : 14.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  AppBackButton(
                    color: Colors.black87,
                    size: isSmallScreen ? 20 : 24,
                    onPressed: () => Navigator.pop(context, _bpm),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context, _bpm),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: brandRed,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Live Slider',
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Main content
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? 24.0 : 32.0),
                child: Column(
                  children: [
                    const SizedBox(height: 40),

                    // Tappable tempo circle
                    Expanded(
                      flex: 4,
                      child: SizedBox(
                        width: double.infinity,
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.center,
                          children: [
                            // Circle outline - tappable area
                            Align(
                              alignment: Alignment.topCenter,
                              child: GestureDetector(
                                onTap: _onTapTempo,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 0),
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                            color: brandRed, width: 3),
                                      ),
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          const SizedBox(height: 16),
                                          const Text(
                                            'TEMPO',
                                            style: TextStyle(
                                              fontFamily: 'Instrument Sans',
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: brandRed,
                                              letterSpacing: 1,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '$_bpm',
                                            style: TextStyle(
                                              fontFamily: 'Instrument Sans',
                                              fontSize: isSmallScreen ? 72 : 90,
                                              fontWeight: FontWeight.w600,
                                              color: brandRed,
                                              height: 1,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          const Text(
                                            'BPM',
                                            style: TextStyle(
                                              fontFamily: 'Instrument Sans',
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.black54,
                                              letterSpacing: 2,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Play button overlapping bottom of circle
                            Positioned(
                              bottom: 65,
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _isPlaying = !_isPlaying;
                                  });
                                },
                                child: Container(
                                  width: 64,
                                  height: 64,
                                  decoration: const BoxDecoration(
                                    color: Colors.black,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    _isPlaying ? Icons.pause : Icons.play_arrow,
                                    color: Colors.white,
                                    size: 34,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Tap instruction text
                    const Text(
                      'Tap in the circle to set the tempo',
                      style: TextStyle(
                        fontFamily: 'Instrument Sans',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: brandRed,
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Beat and Sound sections
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'BEAT',
                                    style: TextStyle(
                                      fontFamily: 'Instrument Sans',
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: brandRed,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '$_beats/4',
                                    style: const TextStyle(
                                      fontFamily: 'Instrument Sans',
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.keyboard_arrow_down,
                                      size: 18, color: Colors.black54),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: List.generate(_beats, (index) {
                                  final isActive = _isPlaying && index == 0;
                                  return GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _beats = index + 1;
                                      });
                                    },
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: BoxDecoration(
                                        color:
                                            isActive ? brandRed : Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.08),
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            index == 0
                                                ? Icons.music_note
                                                : index == 1
                                                    ? Icons.music_note
                                                    : index == 2
                                                        ? Icons.queue_music
                                                        : Icons.grain,
                                            size: 16,
                                            color: isActive
                                                ? Colors.white
                                                : Colors.black54,
                                          ),
                                          Text(
                                            '${index + 1}',
                                            style: TextStyle(
                                              fontFamily: 'Instrument Sans',
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              color: isActive
                                                  ? Colors.white
                                                  : Colors.black54,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 90,
                          margin: const EdgeInsets.symmetric(horizontal: 12),
                          color: Colors.black.withValues(alpha: 0.1),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SOUND',
                              style: TextStyle(
                                fontFamily: 'Instrument Sans',
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: brandRed,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'BEAT',
                              style: TextStyle(
                                fontFamily: 'Instrument Sans',
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Colors.black,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.08),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.volume_up,
                                size: 22,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Volume
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.volume_up,
                              size: 20, color: Colors.black54),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                activeTrackColor: brandRed,
                                inactiveTrackColor: Colors.grey.shade300,
                                thumbColor: brandRed,
                                overlayColor: brandRed.withValues(alpha: 0.12),
                                trackHeight: 4,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6),
                              ),
                              child: Slider(
                                value: _volume,
                                onChanged: (val) =>
                                    setState(() => _volume = val),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
