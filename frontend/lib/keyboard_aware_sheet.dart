import 'package:flutter/material.dart';

/// Lift the entire sheet, not just its scrollable contents, above the keyboard.
class KeyboardAwareSheet extends StatelessWidget {
  const KeyboardAwareSheet({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: child,
      );
}

/// Scroll views have unbounded height: a horizontal Flex must not stretch
/// children along that unbounded axis.
class ResponsivePaymentFields extends StatelessWidget {
  const ResponsivePaymentFields({
    super.key,
    required this.expiry,
    required this.securityCode,
  });

  final Widget expiry;
  final Widget securityCode;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 310
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [expiry, const SizedBox(height: 8), securityCode],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: expiry),
                  const SizedBox(width: 12),
                  Expanded(child: securityCode),
                ],
              ),
      );
}
