import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'verification_code_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isRegistering = false;
  bool _rememberMe = true;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _submitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _submitting) return;
    setState(() => _submitting = true);
    try {
      await AuthService.signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        register: _isRegistering,
      );
    } on AuthException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (!RegExp(r'^\S+@\S+\.\S+$').hasMatch(email)) {
      _showMessage('Enter your email above first.');
      return;
    }
    try {
      await AuthService.sendPasswordReset(email);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VerificationCodePage(
            email: email,
            purpose: VerificationPurpose.password,
          ),
        ),
      );
    } on AuthException catch (error) {
      _showMessage(error.message);
    }
  }

  Future<void> _socialSignIn(Future<void> Function() signIn) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await signIn();
    } on AuthException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFD30A02);
    const cream = Color(0xFFFFF9F5);
    final width = MediaQuery.sizeOf(context).width.clamp(0.0, 600.0);
    final compact = MediaQuery.sizeOf(context).height < 720;
    final heroHeight = (width * .58).clamp(190.0, 330.0);

    return Scaffold(
      backgroundColor: cream,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(21, compact ? 12 : 22, 21, 18),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: heroHeight,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: 0,
                            top: heroHeight * .43,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isRegistering ? 'SIGN UP' : 'LOG IN',
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 38,
                                    fontWeight: FontWeight.w800,
                                    height: .9,
                                  ),
                                ),
                                Container(
                                  width: 101,
                                  height: 2,
                                  margin:
                                      const EdgeInsets.only(top: 8, bottom: 7),
                                  color: red,
                                ),
                                SizedBox(
                                  width: (width - 42) * .46,
                                  child: Text(
                                    _isRegistering
                                        ? 'Create an account to continue'
                                        : 'Log in or sign up to continue',
                                    style: const TextStyle(
                                        fontSize: 14, height: 1.2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            // The supplied PNG includes transparent pixels at its right edge.
                            // Offset those pixels outside the page so the visible sleeve is flush.
                            right: -width * .10,
                            top: -heroHeight * .10,
                            width: width * .78,
                            height: heroHeight * 1.16,
                            child: Image.asset(
                              'assets/login_record_hero.png',
                              fit: BoxFit.contain,
                              alignment: Alignment.topRight,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 5),
                    _label('Email'),
                    _field(
                      controller: _emailController,
                      hint: 'Enter your email',
                      icon: Icons.mail_outline_rounded,
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) => value == null ||
                              !RegExp(r'^\S+@\S+\.\S+$').hasMatch(value)
                          ? 'Enter a valid email address'
                          : null,
                    ),
                    const SizedBox(height: 11),
                    _label('Password'),
                    _field(
                      controller: _passwordController,
                      hint: 'Enter your password',
                      icon: _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      obscure: _obscurePassword,
                      onIconPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      validator: (value) => value == null || value.length < 8
                          ? 'Use at least 8 characters'
                          : null,
                    ),
                    if (_isRegistering) ...[
                      const SizedBox(height: 11),
                      _label('Confirm password'),
                      _field(
                        controller: _confirmPasswordController,
                        hint: 'Enter your password again',
                        icon: _obscureConfirmPassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        obscure: _obscureConfirmPassword,
                        onIconPressed: () => setState(() =>
                            _obscureConfirmPassword = !_obscureConfirmPassword),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please confirm your password';
                          }
                          if (value != _passwordController.text) {
                            return 'Passwords do not match';
                          }
                          return null;
                        },
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 18,
                      children: [
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(
                            height: 22,
                            width: 22,
                            child: Checkbox(
                              value: _rememberMe,
                              activeColor: red,
                              side: const BorderSide(color: Color(0xFF9D9D9D)),
                              onChanged: (value) =>
                                  setState(() => _rememberMe = value ?? false),
                            ),
                          ),
                          const SizedBox(width: 5),
                          const Text('Remember me',
                              style: TextStyle(fontSize: 13)),
                        ]),
                        TextButton(
                          onPressed: _resetPassword,
                          style: TextButton.styleFrom(
                            foregroundColor: red,
                            padding: const EdgeInsets.symmetric(horizontal: 0),
                            minimumSize: const Size(0, 26),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Forgot password?',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _submitting ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: red,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: red.withValues(alpha: .55),
                          elevation: 2,
                          shape: const RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.all(Radius.circular(8))),
                        ),
                        child: _submitting
                            ? const SizedBox(
                                height: 19,
                                width: 19,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : Text(_isRegistering ? 'CREATE ACCOUNT' : 'LOG IN',
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 11),
                    Center(
                      child: Text.rich(
                        TextSpan(
                          text: _isRegistering
                              ? 'Already have an account? '
                              : "Don't have an account? ",
                          style: const TextStyle(
                              fontSize: 13, color: Colors.black),
                          children: [
                            WidgetSpan(
                              child: GestureDetector(
                                onTap: _submitting
                                    ? null
                                    : () {
                                        _formKey.currentState?.reset();
                                        setState(() {
                                          _isRegistering = !_isRegistering;
                                          _confirmPasswordController.clear();
                                          _obscureConfirmPassword = true;
                                        });
                                      },
                                child: Text(
                                  _isRegistering ? 'Log in' : 'Sign up!',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: red,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        Expanded(child: Divider()),
                        Padding(
                            padding: EdgeInsets.symmetric(horizontal: 13),
                            child: Text('or', style: TextStyle(fontSize: 13))),
                        Expanded(child: Divider())
                      ],
                    ),
                    const SizedBox(height: 14),
                    _socialButton(
                      label: 'Continue with Google',
                      icon: Image.asset('assets/google_g_logo.png',
                          width: 21, height: 21),
                      border: const Color(0xFFFF625A),
                      onPressed: () =>
                          _socialSignIn(AuthService.signInWithGoogle),
                    ),
                    SizedBox(height: compact ? 16 : 23),
                    Center(
                      child: Image.asset('assets/augment_logo.png',
                          width: 43, height: 31, fit: BoxFit.contain),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 5),
        child: Text(text,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      );

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required String? Function(String?) validator,
    TextInputType? keyboardType,
    bool obscure = false,
    VoidCallback? onIconPressed,
  }) =>
      TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        validator: validator,
        cursorColor: const Color(0xFFD30A02),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
              fontSize: 15,
              color: Color(0xFFADADAD),
              fontWeight: FontWeight.w400),
          filled: true,
          fillColor: Colors.white.withValues(alpha: .7),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 13, vertical: 0),
          constraints: const BoxConstraints(minHeight: 46),
          prefixIcon: Icon(
            onIconPressed != null
                ? Icons.lock_outline_rounded
                : Icons.mail_outline_rounded,
            size: 18,
            color: const Color(0xFF7E7E7E),
          ),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: Color(0xFFDCDCDC))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: Color(0xFFDCDCDC))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide:
                  const BorderSide(color: Color(0xFFD30A02), width: 1.5)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: Color(0xFFD30A02))),
          focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide:
                  const BorderSide(color: Color(0xFFD30A02), width: 1.5)),
          suffixIcon: onIconPressed == null
              ? null
              : IconButton(
                  tooltip: obscure ? 'Show password' : 'Hide password',
                  icon: Icon(icon, size: 18, color: const Color(0xFF7E7E7E)),
                  onPressed: onIconPressed,
                ),
        ),
      );

  Widget _socialButton(
          {required String label,
          required Widget icon,
          required Color border,
          required VoidCallback onPressed}) =>
      SizedBox(
        width: double.infinity,
        height: 50,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.black,
            side: BorderSide(color: border),
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8))),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(alignment: Alignment.centerLeft, child: icon),
              Text(label, style: const TextStyle(fontSize: 14))
            ],
          ),
        ),
      );
}
