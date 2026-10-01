import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'app_settings.dart';
import 'app_loading.dart';
import 'bakong_payment_service.dart';
import 'auth_service.dart';
import 'firebase_options.dart';
import 'home_page.dart';
import 'generated_sheets_store.dart';
import 'login_page.dart';
import 'social_service.dart';
import 'vector_splash_screen.dart';
import 'supabase_config.dart';
import 'verification_code_page.dart';
import 'welcome_name_page.dart';
import 'app_update_prompt.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Start platform work now, but never hold the first Flutter frame for it.
  // The vector splash is intentionally the first app UI the customer sees.
  final bootstrap = _bootstrapApp();
  runApp(AugmentApp(bootstrap: bootstrap));
}

Future<void> _bootstrapApp() async {
  // Local preferences do not depend on Firebase, so begin that disk read at
  // the same time as platform initialization instead of serializing them.
  final settingsLoad = AppSettings.instance.load();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Supabase needs Firebase to exist for its access-token callback, but it can
  // initialize while the already-started preferences read completes.
  await Future.wait([
    settingsLoad,
    Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
      // Supabase validates Firebase's ID token through the Third-Party Auth integration.
      accessToken: () async =>
          await FirebaseAuth.instance.currentUser?.getIdToken(),
    ),
  ]);
}

Future<void> _refreshStartupAccount() async {
  final userId = FirebaseAuth.instance.currentUser?.uid;
  if (userId != null) {
    // Hydrate the on-device sheet index first. The My Sheets screen reads this
    // cache immediately; the cloud refresh continues independently.
    unawaited(GeneratedSheetsStore.instance.loadLocal());
    unawaited(GeneratedSheetsStore.instance.refreshFromCloud());
    try {
      await AuthService.prepareSupabaseAccess();
    } catch (_) {
      // Account synchronization can retry without holding the launch screen.
    }
    try {
      final subscription = await BakongPaymentService.subscription();
      if (FirebaseAuth.instance.currentUser?.uid == userId) {
        AppSettings.instance.applyServerPlan(subscription.plan);
      }
    } catch (_) {
      // Billing can retry when its screen is opened.
    }
    try {
      await AuthService.ensureProfile();
    } catch (_) {
      // Profile creation will retry after the next successful sign-in.
    }
  }
}

class AugmentApp extends StatelessWidget {
  const AugmentApp({super.key, required this.bootstrap});

  final Future<void> bootstrap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) => MaterialApp(
        title: 'Augment',
        debugShowCheckedModeBanner: false,
        themeMode:
            AppSettings.instance.darkMode ? ThemeMode.dark : ThemeMode.light,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFBA0007),
            surface: Colors.white,
          ),
          scaffoldBackgroundColor: const Color(0xFFFFF9F5),
          fontFamily: 'Instrument Sans',
          inputDecorationTheme: _inputFocusTheme(const Color(0xFFBA0007)),
          dialogTheme: DialogThemeData(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            titleTextStyle: const TextStyle(
              color: Color(0xFF1A1A1A),
              fontFamily: 'Instrument Sans',
              fontWeight: FontWeight.w800,
              fontSize: 22,
            ),
            contentTextStyle: const TextStyle(
              color: Color(0xFF6F6A69),
              fontFamily: 'Instrument Sans',
              fontSize: 14,
              height: 1.4,
            ),
          ),
          bottomSheetTheme: const BottomSheetThemeData(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF302725),
            contentTextStyle: const TextStyle(fontFamily: 'Instrument Sans'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            brightness: Brightness.dark,
            seedColor: const Color(0xFFEA1510),
            surface: const Color(0xFF1D1D1D),
          ),
          scaffoldBackgroundColor: Colors.black,
          fontFamily: 'Instrument Sans',
          inputDecorationTheme: _inputFocusTheme(const Color(0xFFFF625A)),
          dialogTheme: DialogThemeData(
            backgroundColor: const Color(0xFF252525),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            titleTextStyle: const TextStyle(
              color: Colors.white,
              fontFamily: 'Instrument Sans',
              fontWeight: FontWeight.w800,
              fontSize: 22,
            ),
            contentTextStyle: const TextStyle(
              color: Color(0xFFBDB8B7),
              fontFamily: 'Instrument Sans',
              fontSize: 14,
              height: 1.4,
            ),
          ),
          bottomSheetTheme: const BottomSheetThemeData(
            backgroundColor: Color(0xFF252525),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF302725),
            contentTextStyle: const TextStyle(fontFamily: 'Instrument Sans'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          useMaterial3: true,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(AppSettings.instance.textScale),
          ),
          child: AppLoadingHost(child: child ?? const SizedBox.shrink()),
        ),
        home: VectorSplashScreen(
          destinationBuilder: (ready) =>
              _StartupGate(bootstrap: bootstrap, onReady: ready),
        ),
      ),
    );
  }
}

// InputDecorator animates this border when a field gains or loses focus.
// Keep existing field fills/padding and custom borders intact while giving
// borderless search bars, composers and forms an outlined focus indicator.
InputDecorationTheme _inputFocusTheme(Color color) => InputDecorationTheme(
      focusColor: color.withValues(alpha: .08),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: 2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: 2),
      ),
    );

class _StartupGate extends StatefulWidget {
  const _StartupGate({required this.bootstrap, required this.onReady});

  final Future<void> bootstrap;
  final VoidCallback onReady;

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  bool _accountRefreshStarted = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: widget.bootstrap,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // This remains hidden behind the splash while services initialise.
          return const ColoredBox(color: Color(0xFFFFF9F5));
        }
        if (snapshot.hasError) {
          WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady());
          return _StartupFailure(error: snapshot.error);
        }
        if (!_accountRefreshStarted) {
          _accountRefreshStarted = true;
          unawaited(_refreshStartupAccount());
        }
        return AppUpdatePrompt(
          child: _PresenceReporter(child: AuthGate(onReady: widget.onReady)),
        );
      },
    );
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({this.error});
  final Object? error;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFFFFF9F5),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Augment could not start. Please close and reopen the app.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
      );
}

class _PresenceReporter extends StatefulWidget {
  const _PresenceReporter({required this.child});
  final Widget child;

  @override
  State<_PresenceReporter> createState() => _PresenceReporterState();
}

class _PresenceReporterState extends State<_PresenceReporter>
    with WidgetsBindingObserver {
  Timer? _heartbeat;
  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      // Never carry a paid label across accounts on the same device.
      AppSettings.instance.applyServerPlan(AppPlan.free);
      if (user == null) {
        _heartbeat?.cancel();
      } else {
        _startHeartbeat();
        unawaited(_refreshPlanForUser(user.uid));
      }
    });
  }

  Future<void> _refreshPlanForUser(String userId) async {
    try {
      final subscription = await BakongPaymentService.subscription();
      if (FirebaseAuth.instance.currentUser?.uid == userId) {
        AppSettings.instance.applyServerPlan(subscription.plan);
      }
    } catch (_) {
      // The billing screen can retry if the API is temporarily unavailable.
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _reportPresence();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _reportPresence(),
    );
  }

  void _reportPresence() {
    SocialService.instance.updatePresence().catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startHeartbeat();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _reportPresence();
      _heartbeat?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, this.onReady});
  final VoidCallback? onReady;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _reportedReady = false;
  void _reportReady() {
    if (_reportedReady) return;
    _reportedReady = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReady?.call();
    });
  }

  Future<bool>? _nameCheck;
  String? _nameCheckUserId;
  String? _locallyVerifiedUserId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, snapshot) {
        // Firebase restores a persisted native session asynchronously. During a
        // hot reload/restart it can momentarily expose a null currentUser before
        // authStateChanges emits the saved account. Do not send the user back to
        // Login during that short hydration window.
        if (snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null) {
          return const Scaffold(backgroundColor: Color(0xFFFFF9F5));
        }
        final user = snapshot.data;
        if (user != null) {
          final needsEmailCode = !user.emailVerified &&
              user.email != null &&
              user.providerData.any(
                (provider) => provider.providerId == 'password',
              ) &&
              _locallyVerifiedUserId != user.uid;
          if (needsEmailCode) {
            _reportReady();
            return VerificationCodePage(
              email: user.email!,
              purpose: VerificationPurpose.email,
              onEmailVerified: () {
                if (!mounted) return;
                setState(() {
                  _locallyVerifiedUserId = user.uid;
                  _nameCheck = null;
                  _nameCheckUserId = null;
                });
              },
            );
          }
          if (_nameCheckUserId != user.uid) {
            _nameCheckUserId = user.uid;
            _nameCheck = AuthService.needsNameOnboarding();
          }
          return FutureBuilder<bool>(
            future: _nameCheck,
            builder: (context, nameSnapshot) {
              if (!nameSnapshot.hasData) {
                return const Scaffold(backgroundColor: Color(0xFFFFF9F5));
              }
              _reportReady();
              return nameSnapshot.data!
                  ? const WelcomeNamePage()
                  : const AugmentHomePage();
            },
          );
        }
        _nameCheck = null;
        _nameCheckUserId = null;
        _locallyVerifiedUserId = null;
        _reportReady();
        return const LoginPage();
      },
    );
  }
}
