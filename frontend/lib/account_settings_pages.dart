import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'verification_code_page.dart';

const _red = Color(0xFFD30A02);

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key, required this.initialName});

  final String initialName;

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter the name you want people to see.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AuthService.updateDisplayName(name);
      if (mounted) Navigator.pop(context, true);
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AccountPageScaffold(
        title: 'Edit profile',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AccountIntro(
              icon: Icons.person_rounded,
              title: 'What should we call you?',
              detail: 'This name appears on your profile and posts.',
            ),
            const SizedBox(height: 34),
            const Text('Display name',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: TextStyle(color: AppPalette.text(context)),
              decoration: _inputDecoration(context, 'Enter your name'),
              onSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: _red, fontSize: 12)),
            ],
            const SizedBox(height: 24),
            _PrimaryButton(
              label: 'Save changes',
              busy: _saving,
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
      );
}

class PasswordSettingsPage extends StatefulWidget {
  const PasswordSettingsPage({super.key, required this.email});
  final String email;

  @override
  State<PasswordSettingsPage> createState() => _PasswordSettingsPageState();
}

class _PasswordSettingsPageState extends State<PasswordSettingsPage> {
  bool _sending = false;

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await AuthService.sendPasswordReset(widget.email);
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VerificationCodePage(
              email: widget.email,
              purpose: VerificationPurpose.password,
            ),
          ),
        );
      }
    } on AuthException catch (error) {
      if (mounted) _showError(context, error.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AccountPageScaffold(
        title: 'Password',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AccountIntro(
              icon: Icons.lock_rounded,
              title: 'Change your password',
              detail: 'We will email you a secure 6-digit code.',
            ),
            const SizedBox(height: 28),
            Text('Verification code will be sent to',
                style: TextStyle(color: AppPalette.muted(context))),
            const SizedBox(height: 7),
            Text(widget.email,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 26),
            _PrimaryButton(
                label: 'Send verification code',
                busy: _sending,
                onPressed: _sending ? null : _send),
          ],
        ),
      );
}

class EmailSettingsPage extends StatefulWidget {
  const EmailSettingsPage(
      {super.key, required this.email, required this.verified});
  final String email;
  final bool verified;

  @override
  State<EmailSettingsPage> createState() => _EmailSettingsPageState();
}

class _EmailSettingsPageState extends State<EmailSettingsPage> {
  bool _sending = false;

  Future<void> _verify() async {
    setState(() => _sending = true);
    try {
      await AuthService.sendEmailVerification();
      if (mounted) {
        final verified = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => VerificationCodePage(
              email: widget.email,
              purpose: VerificationPurpose.email,
            ),
          ),
        );
        if (verified == true && mounted) Navigator.pop(context, true);
      }
    } on AuthException catch (error) {
      if (mounted) _showError(context, error.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AccountPageScaffold(
        title: 'Email',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AccountIntro(
              icon: Icons.email_rounded,
              title: widget.verified ? 'Email verified' : 'Verify your email',
              detail: widget.verified
                  ? 'Your account email is verified.'
                  : 'Verify your email to keep your account secure.',
            ),
            const SizedBox(height: 28),
            Text('Email address',
                style: TextStyle(color: AppPalette.muted(context))),
            const SizedBox(height: 7),
            Text(widget.email,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            if (!widget.verified) ...[
              const SizedBox(height: 26),
              _PrimaryButton(
                  label: 'Send verification code',
                  busy: _sending,
                  onPressed: _sending ? null : _verify),
            ],
          ],
        ),
      );
}

class _AccountPageScaffold extends StatelessWidget {
  const _AccountPageScaffold({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 15, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppBackButton(
                  onPressed: () => Navigator.maybePop(context),
                ),
                const SizedBox(height: 22),
                RichText(
                  text: TextSpan(
                    text: title,
                    style: TextStyle(
                        color: AppPalette.text(context),
                        fontSize: 25,
                        fontWeight: FontWeight.w800),
                    children: const [
                      TextSpan(text: ' .', style: TextStyle(color: _red))
                    ],
                  ),
                ),
                const SizedBox(height: 34),
                child,
              ],
            ),
          ),
        ),
      );
}

class _AccountIntro extends StatelessWidget {
  const _AccountIntro(
      {required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration:
                const BoxDecoration(color: _red, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white),
          ),
          const SizedBox(width: 13),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(detail,
                    style: TextStyle(
                        color: AppPalette.muted(context),
                        fontSize: 13,
                        height: 1.3)),
              ])),
        ],
      );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton(
      {required this.label, required this.busy, required this.onPressed});
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
              backgroundColor: _red,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          child: busy
              ? const SizedBox(
                  width: 19,
                  height: 19,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      );
}

InputDecoration _inputDecoration(BuildContext context, String hint) =>
    InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppPalette.muted(context)),
      filled: true,
      fillColor: AppPalette.surface(context),
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppPalette.border(context))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _red, width: 1.5)),
    );

void _showError(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
