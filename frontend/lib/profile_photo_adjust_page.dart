import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;

import 'app_palette.dart';

/// Lets a member position a profile image or preview a cover on their profile.
class ProfilePhotoAdjustPage extends StatefulWidget {
  const ProfilePhotoAdjustPage({
    super.key,
    required this.file,
    required this.cover,
    this.profileName,
    this.profileAvatarUrl,
    this.onCoverConfirmed,
  });

  final PlatformFile file;
  final bool cover;
  final String? profileName;
  final String? profileAvatarUrl;
  final Future<bool> Function(PlatformFile file)? onCoverConfirmed;

  @override
  State<ProfilePhotoAdjustPage> createState() => _ProfilePhotoAdjustPageState();
}

class _ProfilePhotoAdjustPageState extends State<ProfilePhotoAdjustPage> {
  static const _red = Color(0xFFCA000A);
  static const _minimumZoom = 1.0;
  static const _maximumZoom = 3.0;
  late final Uint8List _sourceBytes;
  image.Image? _source;
  double _zoom = _minimumZoom;
  double _horizontal = 0;
  double _vertical = 0;
  double _gestureStartZoom = 1;
  double _gestureStartHorizontal = 0;
  double _gestureStartVertical = 0;
  Offset _gestureStartFocalPoint = Offset.zero;
  bool _saving = false;
  bool _uploaded = false;

  // Matches the mobile profile hero.
  double get _aspectRatio => widget.cover ? 1.3 : 1;

  @override
  void initState() {
    super.initState();
    _sourceBytes = widget.file.bytes ?? Uint8List(0);
    _source = image.decodeImage(_sourceBytes);
  }

  Uint8List _adjustedBytes() {
    final source = _source!;
    final sourceAspect = source.width / source.height;
    final baseWidth = sourceAspect > _aspectRatio
        ? source.height * _aspectRatio
        : source.width.toDouble();
    final baseHeight = baseWidth / _aspectRatio;
    final cropWidth = (baseWidth / _zoom).round().clamp(1, source.width);
    final cropHeight = (baseHeight / _zoom).round().clamp(1, source.height);
    final maxX = source.width - cropWidth;
    final maxY = source.height - cropHeight;
    final cropX = (((1 - _horizontal) / 2) * maxX).round().clamp(0, maxX);
    final cropY = (((1 - _vertical) / 2) * maxY).round().clamp(0, maxY);
    final cropped = image.copyCrop(
      source,
      x: cropX,
      y: cropY,
      width: cropWidth,
      height: cropHeight,
    );
    const outputWidth = 1440;
    final outputHeight = (outputWidth / _aspectRatio).round();
    final resized = image.copyResize(
      cropped,
      width: outputWidth,
      height: outputHeight,
      interpolation: image.Interpolation.cubic,
    );
    return Uint8List.fromList(image.encodeJpg(resized, quality: 92));
  }

  Future<void> _save() async {
    if (_source == null || _saving) return;
    setState(() => _saving = true);
    try {
      final bytes = _adjustedBytes();
      final adjusted = PlatformFile(
        name: widget.cover ? 'cover-photo.jpg' : 'profile-photo.jpg',
        size: bytes.length,
        bytes: bytes,
      );
      if (widget.cover && widget.onCoverConfirmed != null) {
        final uploaded = await widget.onCoverConfirmed!(adjusted);
        if (!mounted) return;
        if (!uploaded) {
          setState(() => _saving = false);
          return;
        }
        setState(() => _uploaded = true);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.pop(context, true);
        return;
      }
      if (mounted) Navigator.pop(context, adjusted);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Size _scaledImageSize(double frameWidth, double frameHeight, double zoom) {
    final source = _source!;
    final baseScale = math.max(
      frameWidth / source.width,
      frameHeight / source.height,
    );
    return Size(
      source.width * baseScale * zoom,
      source.height * baseScale * zoom,
    );
  }

  void _startGesture(ScaleStartDetails details) {
    _gestureStartZoom = _zoom;
    _gestureStartHorizontal = _horizontal;
    _gestureStartVertical = _vertical;
    _gestureStartFocalPoint = details.localFocalPoint;
  }

  void _updateGesture(
    ScaleUpdateDetails details,
    double frameWidth,
    double frameHeight,
  ) {
    // A zoom of 1.0 is the image's fitted size: it fills the whole frame.
    // Never allow a smaller value, which would expose empty space at an edge.
    final zoom = (_gestureStartZoom * details.scale)
        .clamp(_minimumZoom, _maximumZoom)
        .toDouble();
    final scaledSize = _scaledImageSize(frameWidth, frameHeight, zoom);
    final maxOffsetX = math.max(0, (scaledSize.width - frameWidth) / 2);
    final movement = details.localFocalPoint - _gestureStartFocalPoint;

    setState(() {
      _zoom = zoom;
      _horizontal = maxOffsetX == 0
          ? 0
          : (_gestureStartHorizontal + movement.dx / maxOffsetX)
              .clamp(-1.0, 1.0);
      // A cover stays vertically centred so its bottom always meets the
      // fixed profile fade. Profile photos keep their free vertical movement.
      _vertical = widget.cover
          ? 0
          : (_gestureStartVertical +
                  movement.dy /
                      math.max(1, (scaledSize.height - frameHeight) / 2))
              .clamp(-1.0, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AppBackButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
              ),
              const SizedBox(width: 2),
              Text(
                widget.cover ? 'Adjust cover photo' : 'Adjust profile photo',
                style: TextStyle(
                  color: text,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              widget.cover
                  ? 'Pinch to zoom, then drag left or right to position the cover.'
                  : 'Drag inside the frame to reposition. Pinch to zoom.',
              style: TextStyle(color: AppPalette.muted(context), fontSize: 13),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Center(
                child: _source == null
                    ? Text(
                        'This image could not be opened.',
                        style: TextStyle(color: AppPalette.muted(context)),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.maxWidth;
                          if (widget.cover) {
                            return _coverProfilePreview(
                              width,
                              constraints.maxHeight,
                            );
                          }
                          return _profilePhotoPreview(
                            width,
                            width.clamp(220.0, 320.0).toDouble(),
                          );
                        },
                      ),
              ),
            ),
            if (_source != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _saving || _uploaded ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: _uploaded ? Colors.green.shade700 : _red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _uploaded
                              ? 'Your cover is uploaded'
                              : widget.cover
                                  ? 'Confirm cover photo'
                                  : 'Use this photo',
                        ),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _profilePhotoPreview(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: _interactivePhoto(width, height, showHint: true),
    );
  }

  Widget _coverProfilePreview(double width, double availableHeight) {
    final coverHeight = width / _aspectRatio;
    final previewHeight = math.min(availableHeight, coverHeight + 235);
    final name = widget.profileName?.trim().isNotEmpty == true
        ? widget.profileName!.trim()
        : 'Your name';

    return SizedBox(
      width: width,
      height: previewHeight,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppPalette.page(context),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .16),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox(
              height: coverHeight,
              width: width,
              child: ClipRect(
                child: _interactivePhoto(width, coverHeight, showHint: false),
              ),
            ),
            Positioned(
              top: coverHeight - 47,
              left: (width - 94) / 2,
              child: _avatarPreview(name),
            ),
            Positioned(
              top: coverHeight + 56,
              left: 16,
              right: 16,
              child: Column(
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    '@you',
                    style: TextStyle(
                      color: _red,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Music is better when it is shared.',
                    style: TextStyle(
                      color: AppPalette.muted(context),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Edit profile',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatarPreview(String name) {
    final fallback = Container(
      color: _red,
      alignment: Alignment.center,
      child: Text(
        name.substring(0, 1).toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 34,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return Container(
      width: 94,
      height: 94,
      padding: const EdgeInsets.all(3),
      decoration:
          const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: ClipOval(
        child: widget.profileAvatarUrl == null
            ? fallback
            : Image.network(
                widget.profileAvatarUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }

  Widget _interactivePhoto(
    double width,
    double height, {
    required bool showHint,
  }) {
    final scaledSize = _scaledImageSize(width, height, _zoom);
    final imageOffset = Offset(
      _horizontal * math.max(0, (scaledSize.width - width) / 2),
      _vertical * math.max(0, (scaledSize.height - height) / 2),
    );
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _startGesture,
          onScaleUpdate: (details) => _updateGesture(details, width, height),
          child: Transform.translate(
            offset: imageOffset,
            child: Transform.scale(
              scale: _zoom,
              child: Image.memory(
                _sourceBytes,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: widget.cover
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppPalette.page(context).withValues(alpha: 0),
                        AppPalette.page(context).withValues(alpha: .08),
                        AppPalette.page(context).withValues(alpha: .48),
                        AppPalette.page(context),
                      ],
                      stops: const [0, .42, .78, 1],
                    )
                  : const LinearGradient(
                      colors: [Colors.transparent, Colors.transparent],
                    ),
            ),
          ),
        ),
        if (showHint)
          IgnorePointer(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .46),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Drag to move - Pinch to zoom',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
