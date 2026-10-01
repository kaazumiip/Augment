import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'auth_service.dart';

enum VerificationPurpose { email, password }

class VerificationCodePage extends StatefulWidget {
  const VerificationCodePage({
    super.key,
    required this.email,
    required this.purpose,
    this.onEmailVerified,
  });

  final String email;
  final VerificationPurpose purpose;
  final VoidCallback? onEmailVerified;

  @override
  State<VerificationCodePage> createState() => _VerificationCodePageState();
}

class _VerificationCodePageState extends State<VerificationCodePage>
    with SingleTickerProviderStateMixin {
  static const _red = Color(0xFFD30A02);
  final _code = TextEditingController();
  final _focus = FocusNode();
  late final AnimationController _success;
  Timer? _timer;
  int _seconds = 60;
  bool _checking = false;
  bool _resending = false;
  String? _error;

  bool get _isPassword => widget.purpose == VerificationPurpose.password;

  @override
  void initState() {
    super.initState();
    _success = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _seconds = 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_seconds <= 1) {
        timer.cancel();
        setState(() => _seconds = 0);
      } else {
        setState(() => _seconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    _success.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_checking || _code.text.length != 6) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      String? resetToken;
      if (_isPassword) {
        resetToken =
            await AuthService.verifyPasswordCode(widget.email, _code.text);
      } else {
        await AuthService.verifyEmailCode(_code.text);
      }
      if (!mounted) return;
      await _success.forward(from: 0);
      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (!mounted) return;
      if (_isPassword) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => NewPasswordPage(resetToken: resetToken!),
          ),
        );
      } else if (widget.onEmailVerified != null) {
        widget.onEmailVerified!();
      } else {
        Navigator.pop(context, true);
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      HapticFeedback.vibrate();
      setState(() {
        _error = error.message;
        _checking = false;
        _code.clear();
      });
      _focus.requestFocus();
    }
  }

  Future<void> _resend() async {
    if (_resending || _seconds > 0) return;
    setState(() {
      _resending = true;
      _error = null;
    });
    try {
      if (_isPassword) {
        await AuthService.sendPasswordReset(widget.email);
      } else {
        await AuthService.sendEmailVerification();
      }
      if (mounted) _startTimer();
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = AppPalette.text(context);
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 34),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    ),
                  ),
                  Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      color: _red.withValues(alpha: .1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.mark_email_read_rounded,
                        color: _red, size: 36),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _isPassword ? 'Check your email' : 'Verify your email',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: text,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -.6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'We sent a 6-digit code to\n${widget.email}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppPalette.muted(context),
                      height: 1.5,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 32),
                  GestureDetector(
                    onTap: _focus.requestFocus,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Opacity(
                          opacity: 0,
                          child: TextField(
                            controller: _code,
                            focusNode: _focus,
                            autofocus: true,
                            keyboardType: TextInputType.number,
                            autofillHints: const [AutofillHints.oneTimeCode],
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6),
                            ],
                            onChanged: (_) {
                              setState(() => _error = null);
                              if (_code.text.length == 6) _verify();
                            },
                          ),
                        ),
                        AnimatedBuilder(
                          animation: _success,
                          builder: (context, _) => Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: List.generate(6, (index) {
                              final start = index * .09;
                              final end = (start + .42).clamp(0.0, 1.0);
                              final curved = CurvedAnimation(
                                parent: _success,
                                curve: Interval(start, end,
                                    curve: Curves.elasticOut),
                              ).value;
                              final filled = index < _code.text.length;
                              return Transform.translate(
                                offset: Offset(0, -10 * curved),
                                child: Transform.scale(
                                  scale: 1 + .09 * curved,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    width: 42,
                                    height: 58,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: _success.value > 0
                                          ? const Color(0xFFEAF8EF)
                                          : (dark
                                              ? const Color(0xFF242424)
                                              : Colors.white),
                                      borderRadius: BorderRadius.circular(13),
                                      border: Border.all(
                                        color: _success.value > 0
                                            ? const Color(0xFF2DA865)
                                            : filled
                                                ? _red
                                                : const Color(0xFFD8D1CE),
                                        width: filled ? 1.8 : 1,
                                      ),
                                      boxShadow: filled
                                          ? [
                                              BoxShadow(
                                                color:
                                                    _red.withValues(alpha: .1),
                                                blurRadius: 12,
                                                offset: const Offset(0, 5),
                                              )
                                            ]
                                          : null,
                                    ),
                                    child: Text(
                                      filled ? _code.text[index] : '',
                                      style: TextStyle(
                                        color: text,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    child: _error == null
                        ? const SizedBox(height: 24)
                        : Padding(
                            padding: const EdgeInsets.only(top: 14, bottom: 8),
                            child: Text(_error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: _red,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _red,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13)),
                      ),
                      onPressed:
                          _checking || _code.text.length != 6 ? null : _verify,
                      child: _checking
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('VERIFY CODE',
                              style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: _seconds == 0 && !_resending ? _resend : null,
                    child: Text(_resending
                        ? 'Sending…'
                        : _seconds > 0
                            ? 'Resend code in ${_seconds}s'
                            : 'Resend code'),
                  ),
                  Text('Code expires after 10 minutes',
                      style: TextStyle(
                          color: AppPalette.muted(context), fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NewPasswordPage extends StatefulWidget {
  const NewPasswordPage({super.key, required this.resetToken});
  final String resetToken;

  @override
  State<NewPasswordPage> createState() => _NewPasswordPageState();
}

class _NewPasswordPageState extends State<NewPasswordPage> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _hidden = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_password.text.length < 8) {
      return setState(() => _error = 'Use at least 8 characters.');
    }
    if (_password.text != _confirm.text) {
      return setState(() => _error = 'The passwords do not match.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.changePasswordWithCode(
          widget.resetToken, _password.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password changed successfully.')));
      Navigator.popUntil(context, (route) => route.isFirst);
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('New password'),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                const Text('Create a new password',
                    style:
                        TextStyle(fontSize: 27, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Text('Use at least 8 characters that you have not used before.',
                    style: TextStyle(color: AppPalette.muted(context))),
                const SizedBox(height: 30),
                TextField(
                  controller: _password,
                  obscureText: _hidden,
                  decoration: InputDecoration(
                    labelText: 'New password',
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _hidden = !_hidden),
                      icon: Icon(_hidden
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _confirm,
                  obscureText: _hidden,
                  decoration:
                      const InputDecoration(labelText: 'Confirm password'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: Color(0xFFD30A02))),
                ],
                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFD30A02)),
                    onPressed: _busy ? null : _save,
                    child: _busy
                        ? const CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white)
                        : const Text('CHANGE PASSWORD',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
