import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppPlan { free, plus, pro }

class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final instance = AppSettings._();
  static const _darkModeKey = 'settings_dark_mode';
  static const _textScaleKey = 'settings_text_scale';

  static const smallTextScale = 1.0;
  static const mediumTextScale = 1.15;
  static const largeTextScale = 1.3;

  bool darkMode = false;
  double textScale = mediumTextScale;
  AppPlan plan = AppPlan.free;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    darkMode = preferences.getBool(_darkModeKey) ?? false;
    // Paid access is never restored from an editable device preference.
    // The authenticated billing endpoint applies the current server plan.
    plan = AppPlan.free;
    final savedScale = preferences.getDouble(_textScaleKey);
    // Move choices saved by the previous, smaller scale range to the new
    // equivalent so existing users see the improved sizing immediately.
    if (savedScale == null) {
      textScale = mediumTextScale;
    } else if (savedScale <= 1.05) {
      textScale = smallTextScale;
    } else if (savedScale >= 1.25) {
      textScale = largeTextScale;
    } else {
      textScale = mediumTextScale;
    }
    notifyListeners();
  }

  Future<void> setDarkMode(bool value) async {
    darkMode = value;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_darkModeKey, value);
  }

  Future<void> setTextScale(double value) async {
    textScale = value;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_textScaleKey, value);
  }

  /// The server is the source of truth for paid access. This intentionally
  /// does not persist a paid entitlement on the device.
  void applyServerPlan(AppPlan value) {
    if (plan == value) return;
    plan = value;
    notifyListeners();
  }

  String get planLabel => switch (plan) {
        AppPlan.free => 'Free',
        AppPlan.plus => 'Plus',
        AppPlan.pro => 'Pro',
      };

  String get fontSizeLabel {
    if (textScale == smallTextScale) return 'Small';
    if (textScale == largeTextScale) return 'Large';
    return 'Medium';
  }
}
