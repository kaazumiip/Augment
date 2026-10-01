import 'package:flutter/material.dart';

/// A profile image with a consistent initial fallback throughout Social.
class SocialAccountAvatar extends StatelessWidget {
  const SocialAccountAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.size = 48,
  });

  final String name;
  final String? imageUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: const Color(0xFFE9E7E5),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(
          color: const Color(0xFF9F9B98),
          fontSize: size * .42,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: imageUrl == null || imageUrl!.isEmpty
            ? fallback
            : Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}
