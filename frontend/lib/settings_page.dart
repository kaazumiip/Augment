import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'auth_service.dart';
import 'saved_posts_page.dart';
import 'account_settings_pages.dart';
import 'app_palette.dart';
import 'manage_plan_page.dart';
import 'plans_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _red = Color(0xFFD30A02);
  bool _busy = false;

  User? get _user => FirebaseAuth.instance.currentUser;

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openEditProfile() async {
    final initialName = _user?.displayName?.isNotEmpty == true
        ? _user!.displayName!
        : _user?.email?.split('@').first ?? '';
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EditProfilePage(initialName: initialName),
      ),
    );
    if (updated == true && mounted) {
      setState(() {});
      _message('Name updated.');
    }
  }

  Future<void> _openPasswordSettings() async {
    final email = _user?.email;
    if (email == null) return _message('This account has no email address.');
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PasswordSettingsPage(email: email)),
    );
    if (sent == true && mounted) _message('Password reset email sent.');
  }

  Future<void> _openEmailSettings() async {
    final email = _user?.email;
    if (email == null) return _message('This account has no email address.');
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EmailSettingsPage(
          email: email,
          verified: _user?.emailVerified == true,
        ),
      ),
    );
    if (sent == true && mounted) _message('Verification email sent.');
  }

  // ignore: unused_element
  Future<void> _editProfile() async {
    final controller = TextEditingController(
      text: _user?.displayName?.isNotEmpty == true
          ? _user!.displayName
          : _user?.email?.split('@').first,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await AuthService.updateDisplayName(name);
      if (mounted) setState(() {});
      _message('Profile updated.');
    } on AuthException catch (error) {
      _message(error.message);
    }
  }

  // ignore: unused_element
  Future<void> _sendPasswordReset() async {
    final email = _user?.email;
    if (email == null) return _message('This account has no email address.');
    try {
      await AuthService.sendPasswordReset(email);
      _message('Password reset email sent.');
    } on AuthException catch (error) {
      _message(error.message);
    }
  }

  // ignore: unused_element
  Future<void> _verifyEmail() async {
    try {
      await AuthService.sendEmailVerification();
      _message('Verification email sent.');
    } on AuthException catch (error) {
      _message(error.message);
    }
  }

  Future<void> _signOut() async {
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        final dark = Theme.of(sheetContext).brightness == Brightness.dark;
        final surface = AppPalette.surface(sheetContext);
        final text = AppPalette.text(sheetContext);
        final muted = AppPalette.muted(sheetContext);
        final border = dark ? const Color(0xFF3C3C3C) : const Color(0xFFF0D8D3);
        return SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 26),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(30),
              ),
              border: Border.all(color: border),
              boxShadow: [
                BoxShadow(
                  color: _red.withValues(alpha: dark ? .22 : .12),
                  blurRadius: 30,
                  offset: const Offset(0, -7),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _red,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.logout_rounded, color: _red),
                ),
                const SizedBox(height: 16),
                Text(
                  'Sign out?',
                  style: TextStyle(
                    color: text,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.4,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'You will need to sign in again to access your account.',
                  style: TextStyle(color: muted, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(sheetContext, false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: text,
                          side: BorderSide(
                            color: AppPalette.border(sheetContext),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        child: const Text('Stay signed in'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        onPressed: () => Navigator.pop(sheetContext, true),
                        child: const Text('Sign out'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    await AuthService.signOut();
  }

  Future<void> _chooseFontSize() async {
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final dark = Theme.of(sheetContext).brightness == Brightness.dark;
        final current = AppSettings.instance.textScale;
        final text = AppPalette.text(sheetContext);
        final muted = AppPalette.muted(sheetContext);
        return SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 26),
            decoration: BoxDecoration(
              color: AppPalette.surface(sheetContext),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(30)),
              border: Border.all(
                color: dark ? const Color(0xFF3C3C3C) : const Color(0xFFF0D8D3),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _red,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 23),
                Text('Font size',
                    style: TextStyle(
                        color: text,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.4)),
                const SizedBox(height: 6),
                Text('Choose the reading size that feels most comfortable.',
                    style: TextStyle(color: muted, fontSize: 14)),
                const SizedBox(height: 18),
                for (final option in const <(String, double, String)>[
                  ('Small', AppSettings.smallTextScale, 'Compact and clear'),
                  ('Medium', AppSettings.mediumTextScale, 'Recommended size'),
                  ('Large', AppSettings.largeTextScale, 'Extra readable'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _FontScaleOption(
                      label: option.$1,
                      description: option.$3,
                      scale: option.$2,
                      selected: (current - option.$2).abs() < .01,
                      onTap: () => Navigator.pop(sheetContext, option.$2),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null) await AppSettings.instance.setTextScale(selected);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textColor = dark ? Colors.white : Colors.black;
    final muted = dark ? const Color(0xFFB8B8B8) : const Color(0xFF7A7A7A);
    final border = dark ? const Color(0xFFE1E1E1) : const Color(0xFFD9D9D9);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(27, 26, 27, 126),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppBackButton(
              color: textColor,
              size: 21,
              onPressed: () => Navigator.maybePop(context),
            ),
            const SizedBox(height: 22),
            RichText(
              text: TextSpan(
                text: 'Settings',
                style: TextStyle(
                  color: textColor,
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                ),
                children: const [
                  TextSpan(
                    text: ' .',
                    style: TextStyle(color: _red),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            _sectionTitle('Account', textColor),
            const SizedBox(height: 11),
            _group(border, [
              _SettingsTile(
                icon: Icons.person_rounded,
                title: 'Edit name',
                subtitle: _user?.displayName?.isNotEmpty == true
                    ? _user!.displayName!
                    : 'Change your name',
                onTap: _openEditProfile,
              ),
              _SettingsTile(
                icon: Icons.lock_rounded,
                title: 'Change your password',
                subtitle: 'Verify with a secure email code',
                onTap: _openPasswordSettings,
              ),
              _SettingsTile(
                icon: Icons.email_rounded,
                title: 'Email',
                subtitle: _user?.emailVerified == true
                    ? (_user?.email ?? '')
                    : 'Verify ${_user?.email ?? 'your email'}',
                onTap: _openEmailSettings,
              ),
              ListenableBuilder(
                listenable: AppSettings.instance,
                builder: (context, _) => _SettingsTile(
                  icon: Icons.workspace_premium_rounded,
                  title: 'Plans & billing',
                  subtitle: '${AppSettings.instance.planLabel} plan',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PlansPage()),
                  ),
                ),
              ),
              _SettingsTile(
                icon: Icons.credit_card_rounded,
                title: 'Manage plan',
                subtitle: 'Payments and cancellation',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ManagePlanPage()),
                ),
              ),
            ]),
            const SizedBox(height: 25),
            _sectionTitle('General', textColor),
            const SizedBox(height: 11),
            ListenableBuilder(
              listenable: AppSettings.instance,
              builder: (context, _) => _group(border, [
                _SettingsTile(
                  icon: Icons.bookmark_rounded,
                  title: 'Saved posts',
                  subtitle: 'Open posts you saved',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SavedPostsPage()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.dark_mode_rounded,
                  title: 'Dark mode',
                  subtitle: 'Use dark theme',
                  trailing: Switch.adaptive(
                    value: AppSettings.instance.darkMode,
                    activeTrackColor: _red,
                    onChanged: AppSettings.instance.setDarkMode,
                  ),
                ),
                _SettingsTile(
                  icon: Icons.text_fields_rounded,
                  title: 'Font size',
                  subtitle: 'Adjust your font size',
                  trailing: Tooltip(
                    message: 'Choose font size',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _chooseFontSize,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              AppSettings.instance.fontSizeLabel,
                              style: const TextStyle(
                                color: _red,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: 3),
                            const Icon(Icons.expand_more_rounded,
                                color: _red, size: 17),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _signOut,
                icon: _busy
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout_rounded),
                label: const Text(
                  'Sign out',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _red,
                  side: const BorderSide(color: _red),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _user?.email ?? '',
                style: TextStyle(color: muted, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, Color color) => Padding(
        padding: const EdgeInsets.only(left: 3),
        child: Text(
          title,
          style: TextStyle(
              color: color, fontSize: 13, fontWeight: FontWeight.w700),
        ),
      );

  Widget _group(Color border, List<Widget> children) => Container(
        decoration: BoxDecoration(
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(children: children),
      );
}

class _FontScaleOption extends StatelessWidget {
  const _FontScaleOption({
    required this.label,
    required this.description,
    required this.scale,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String description;
  final double scale;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(17),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFD30A02).withValues(alpha: .10)
              : AppPalette.page(context),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color:
                selected ? const Color(0xFFD30A02) : AppPalette.border(context),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 45,
              child: Text('Aa',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: text,
                      fontSize: 16 * scale,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: text,
                          fontSize: 14,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(description,
                      style: TextStyle(
                          color: AppPalette.muted(context), fontSize: 11)),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle_rounded,
                  color: Color(0xFFD30A02), size: 22),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      dense: true,
      minVerticalPadding: 11,
      contentPadding: const EdgeInsets.symmetric(horizontal: 15),
      leading: Container(
        width: 29,
        height: 29,
        decoration: const BoxDecoration(
          color: Color(0xFFD30A02),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 16),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: dark ? Colors.white : Colors.black,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: dark ? const Color(0xFFB8B8B8) : const Color(0xFF7A7A7A),
          fontSize: 9,
        ),
      ),
      trailing: trailing,
    );
  }
}
