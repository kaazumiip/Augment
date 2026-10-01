import 'package:flutter/material.dart';

/// A single app-wide blocking progress surface for short user-initiated work
/// such as uploads, saves, checkout requests, and sending attachments.
class AppLoading {
  AppLoading._();

  static final ValueNotifier<_LoadingState?> _state = ValueNotifier(null);

  static Future<T> run<T>(
    Future<T> Function() action, {
    String message = 'Please wait…',
  }) async {
    _state.value = _LoadingState(message);
    try {
      return await action();
    } finally {
      _state.value = null;
    }
  }
}

class _LoadingState {
  const _LoadingState(this.message);
  final String message;
}

class AppLoadingHost extends StatelessWidget {
  const AppLoadingHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_LoadingState?>(
        valueListenable: AppLoading._state,
        builder: (context, loading, _) => Stack(children: [
          child,
          if (loading != null)
            Positioned.fill(
              child: PopScope(
                canPop: false,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .30),
                  child: Center(
                    child: Container(
                      width: 190,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 20),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(
                            color: Color(0xFFBA0007),
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: 13),
                        Text(
                          loading.message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
}
