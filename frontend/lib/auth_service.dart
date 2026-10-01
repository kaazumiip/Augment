import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' hide User;

import 'generated_sheets_store.dart';
import 'api_config.dart';

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AuthService {
  static final _auth = FirebaseAuth.instance;
  static final _google = GoogleSignIn.instance;
  static Future<void>? _googleInitialization;

  static Future<void> signIn({
    required String email,
    required String password,
    required bool register,
  }) async {
    try {
      if (register) {
        await _auth.createUserWithEmailAndPassword(
            email: email, password: password);
      } else {
        await _auth.signInWithEmailAndPassword(
            email: email, password: password);
      }
      await _syncSupabaseRole();
      await ensureProfile();
      if (register && _auth.currentUser?.emailVerified == false) {
        await sendEmailVerification();
      }
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    }
  }

  static Future<void> signInWithGoogle() async {
    try {
      if (kIsWeb) {
        await _auth.signInWithPopup(GoogleAuthProvider());
        return;
      }
      if (!_google.supportsAuthenticate()) {
        throw const AuthException(
            'Google sign-in is not available on this device.');
      }
      _googleInitialization ??= _google.initialize();
      await _googleInitialization;
      final account = await _google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AuthException('Google did not return an ID token.');
      }
      await _auth.signInWithCredential(
          GoogleAuthProvider.credential(idToken: idToken));
      await _syncSupabaseRole();
      await ensureProfile();
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    }
  }

  static Future<void> signInWithApple() async {
    try {
      final provider = AppleAuthProvider();
      if (kIsWeb) {
        await _auth.signInWithPopup(provider);
      } else {
        await _auth.signInWithProvider(provider);
      }
      await _syncSupabaseRole();
      await ensureProfile();
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    }
  }

  static Future<void> sendPasswordReset(String email) async {
    final cleanEmail = email.trim();
    for (final server in ApiConfig.baseUrls) {
      try {
        final response = await http
            .post(
              Uri.parse('$server/api/auth/send-password-code'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': cleanEmail}),
            )
            .timeout(const Duration(seconds: 12));
        if (response.statusCode >= 200 && response.statusCode < 300) return;
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        final message = data?['error']?.toString();
        if (message != null && response.statusCode != 503) {
          throw AuthException(message);
        }
      } on AuthException {
        rethrow;
      } catch (_) {}
    }
    throw const AuthException('The email service is unavailable right now.');
  }

  static Future<String> verifyPasswordCode(String email, String code) async {
    for (final server in ApiConfig.baseUrls) {
      try {
        final response = await http
            .post(
              Uri.parse('$server/api/auth/verify-password-code'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email.trim(), 'code': code}),
            )
            .timeout(const Duration(seconds: 12));
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final token = data?['resetToken']?.toString();
          if (token != null && token.isNotEmpty) return token;
        }
        final message = data?['error']?.toString();
        if (message != null && response.statusCode != 503) {
          throw AuthException(message);
        }
      } on AuthException {
        rethrow;
      } catch (_) {}
    }
    throw const AuthException('Unable to verify the code right now.');
  }

  static Future<void> changePasswordWithCode(
      String resetToken, String newPassword) async {
    for (final server in ApiConfig.baseUrls) {
      try {
        final response = await http
            .post(
              Uri.parse('$server/api/auth/change-password-with-code'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(
                  {'resetToken': resetToken, 'newPassword': newPassword}),
            )
            .timeout(const Duration(seconds: 12));
        if (response.statusCode >= 200 && response.statusCode < 300) return;
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        final message = data?['error']?.toString();
        if (message != null && response.statusCode != 503) {
          throw AuthException(message);
        }
      } on AuthException {
        rethrow;
      } catch (_) {}
    }
    throw const AuthException('Unable to change the password right now.');
  }

  static Future<void> updateDisplayName(String displayName) async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthException('You are no longer signed in.');
    try {
      await user.updateDisplayName(displayName.trim());
      await ensureProfile();
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    }
  }

  static Future<bool> needsNameOnboarding() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      final profile = await Supabase.instance.client
          .from('profiles')
          .select('onboarding_completed')
          .eq('id', user.uid)
          .maybeSingle();
      return profile?['onboarding_completed'] != true;
    } catch (_) {
      // Older databases without the new column still ask users with no name.
      return user.displayName?.trim().isEmpty ?? true;
    }
  }

  static Future<void> completeNameOnboarding(String displayName) async {
    await updateDisplayName(displayName);
    final user = _auth.currentUser;
    if (user == null) throw const AuthException('You are no longer signed in.');
    try {
      await Supabase.instance.client.from('profiles').upsert({
        'id': user.uid,
        'display_name': displayName.trim(),
        'onboarding_completed': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');
    } catch (_) {
      // Firebase keeps the name even if an older Supabase schema has not been migrated yet.
    }
  }

  static Future<void> sendEmailVerification() async {
    final user = _auth.currentUser;
    if (user == null || user.email == null) {
      throw const AuthException('There is no email address on this account.');
    }
    if (user.emailVerified) return;

    final idToken = await user.getIdToken();
    if (idToken != null) {
      for (final server in ApiConfig.baseUrls) {
        try {
          final response = await http.post(
            Uri.parse('$server/api/auth/send-verification-code'),
            headers: {'Authorization': 'Bearer $idToken'},
          ).timeout(const Duration(seconds: 12));
          if (response.statusCode >= 200 && response.statusCode < 300) return;
          final data = jsonDecode(response.body) as Map<String, dynamic>?;
          final message = data?['error']?.toString();
          if (response.statusCode == 429 && message != null) {
            throw AuthException(message);
          }
          if (response.statusCode != 503) continue;
        } on AuthException {
          rethrow;
        } catch (_) {
          // Try the next configured server.
        }
      }
    }

    throw const AuthException('The verification service is unavailable.');
  }

  static Future<void> verifyEmailCode(String code) async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthException('You are no longer signed in.');
    final idToken = await user.getIdToken();
    if (idToken == null) throw const AuthException('Your session has expired.');

    for (final server in ApiConfig.baseUrls) {
      try {
        final response = await http
            .post(
              Uri.parse('$server/api/auth/verify-email-code'),
              headers: {
                'Authorization': 'Bearer $idToken',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'code': code}),
            )
            .timeout(const Duration(seconds: 12));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          await user.reload();
          await user.getIdToken(true);
          return;
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        final message = data?['error']?.toString();
        if (message != null && response.statusCode != 503) {
          throw AuthException(message);
        }
      } on AuthException {
        rethrow;
      } catch (_) {}
    }
    throw const AuthException('Unable to verify the code right now.');
  }

  static Future<void> signOut() async {
    GeneratedSheetsStore.instance.clearSession();
    await _auth.signOut();
  }

  static Future<void> prepareSupabaseAccess() => _syncSupabaseRole();

  static Future<void> ensureProfile() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final emailName = user.email?.split('@').first;
    final displayName = user.displayName?.trim();
    await Supabase.instance.client.from('profiles').upsert({
      'id': user.uid,
      'display_name': displayName?.isNotEmpty == true
          ? displayName
          : (emailName ?? 'Augment user'),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'id');
  }

  static Future<void> _syncSupabaseRole() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('Firebase did not finish signing you in.');
    }
    final idToken = await user.getIdToken();
    if (idToken == null) {
      throw const AuthException(
          'Firebase did not return a valid session token.');
    }

    for (final server in ApiConfig.baseUrls) {
      try {
        final response = await http.post(
          Uri.parse('$server/api/auth/supabase-role'),
          headers: {'Authorization': 'Bearer $idToken'},
        ).timeout(const Duration(seconds: 6));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (response.body.contains('"roleUpdated":true')) {
            await user.getIdToken(true);
          }
          return;
        }
      } catch (_) {}
    }
    throw const AuthException(
        'Signed in, but the app server is unavailable to prepare database access.');
  }

  static String _messageFor(FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email or password is incorrect.';
      case 'email-already-in-use':
        return 'An account with this email already exists.';
      case 'weak-password':
        return 'Use a stronger password of at least 8 characters.';
      case 'network-request-failed':
        return 'Check your internet connection and try again.';
      default:
        return error.message ?? 'Authentication failed. Please try again.';
    }
  }
}
