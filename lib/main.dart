// lib/main.dart
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'pokemon_tcg_api.dart';
import 'collection_store.dart';
import 'pokemon_ocr.dart';
import 'pokemon_models.dart';
import 'card_showcase_screen.dart';
import 'pokemon_card_showcase.dart';
import 'dart:ui' show lerpDouble;
import 'dart:ui';
import 'featured_card.dart';
import 'firebase_options.dart';

List<CameraDescription> gCameras = const [];
const bool kEnableLiveScanPrototype = true;

bool _hasPersistentCollectionAccess(User? user) {
  return user != null && !user.isAnonymous;
}

String _accountIdentifier(User user) {
  final email = user.email?.trim();
  if (email != null && email.isNotEmpty) return email;

  final shortUid = user.uid.length > 8 ? user.uid.substring(0, 8) : user.uid;
  if (user.isAnonymous) return 'Guest ($shortUid)';
  return 'User ($shortUid)';
}

String _accountStatusTitle(User? user) {
  if (user == null) return 'Signed out';
  return user.isAnonymous ? 'Guest test mode' : 'Signed in';
}

String _accountOwnershipExplanation(User? user) {
  if (user == null) {
    return 'You can continue as a guest to test scanning and search on this device, but saving cards requires a real account.';
  }
  if (user.isAnonymous) {
    return 'You are in guest test mode. You can scan and search cards, but saving cards and Pokédex ownership require a real account.';
  }
  return 'You are signed in. Your collection still works on this device, and signed-in sessions can sync card data to cloud. Older local or demo data may not automatically move between users.';
}

String? getCurrentUserId() {
  return FirebaseAuth.instance.currentUser?.uid;
}

String _accountActionLabel(User? user) {
  if (user == null) return 'Continue as guest';
  if (user.isAnonymous) return 'Exit guest mode';
  return 'Sign out';
}

IconData _accountActionIcon(User? user) {
  if (user == null) return Icons.science_outlined;
  return Icons.logout_rounded;
}

Widget _buildAccountActionButtons(BuildContext context, User? user) {
  if (user == null || user.isAnonymous) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton(
          onPressed: () => _handleAuthAction(context, user: user),
          child: Text(_accountActionLabel(user)),
        ),
        FilledButton(
          onPressed: () => _startCreateAccountFlow(context),
          child: const Text('Create account'),
        ),
        OutlinedButton(
          onPressed: () => _startSignInFlow(context),
          child: const Text('Sign in'),
        ),
      ],
    );
  }

  return TextButton(
    onPressed: () => _handleAuthAction(context, user: user),
    child: Text(_accountActionLabel(user)),
  );
}

Future<void> _handleAuthAction(
  BuildContext context, {
  required User? user,
}) async {
  try {
    if (user == null) {
      final credential = await FirebaseAuth.instance.signInAnonymously();
      if (!context.mounted) return;
      final signedInUser = credential.user;
      final shortUid = signedInUser == null
          ? null
          : (signedInUser.uid.length > 8
                ? signedInUser.uid.substring(0, 8)
                : signedInUser.uid);
      final signedInLabel = shortUid == null ? 'guest' : 'guest ($shortUid)';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Continuing as $signedInLabel.')));
      return;
    }

    await FirebaseAuth.instance.signOut();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(user.isAnonymous ? 'Exited guest mode.' : 'Signed out.'),
      ),
    );
  } on FirebaseAuthException catch (e) {
    if (!context.mounted) return;
    final message = e.code == 'operation-not-allowed'
        ? 'Guest mode is not enabled in Firebase Auth yet.'
        : 'Sign-in failed: ${e.message ?? e.code}';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Authentication failed: $e')));
  }
}

Future<void> _showAccountRequiredToSavePrompt(BuildContext context) async {
  final shouldCreateAccount = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Save your collection'),
        content: const Text(
          'You found your card. Create an account to save it to your collection and track your Pokédex.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep browsing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create account'),
          ),
        ],
      );
    },
  );

  if (shouldCreateAccount != true || !context.mounted) return;

  await _startCreateAccountFlow(context);
}

Future<void> _startCreateAccountFlow(BuildContext context) async {
  debugPrint('AUTH FLOW >>> create account route opened');
  final created = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => const CreateAccountScreen()));

  debugPrint('AUTH FLOW >>> create account route returned created=$created');
  if (created != true || !context.mounted) return;

  debugPrint(
    'AUTH FLOW >>> post-auth navigation triggered source=create-account',
  );
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Account created. You can now save cards.')),
  );
}

Future<void> _startSignInFlow(BuildContext context) async {
  debugPrint('AUTH FLOW >>> sign in route opened');
  final signedIn = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => const SignInScreen()));

  debugPrint('AUTH FLOW >>> sign in route returned signedIn=$signedIn');
  if (signedIn != true || !context.mounted) return;

  debugPrint('AUTH FLOW >>> post-auth navigation triggered source=sign-in');
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Signed in. You can now save cards.')),
  );
}

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();
  bool _submitting = false;

  bool _looksLikeEmail(String value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
  }

  String _messageForAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return 'That email is already in use.';
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'operation-not-allowed':
        return 'Email/password sign-up is not enabled in Firebase Auth yet.';
      case 'network-request-failed':
        return 'Network error while creating account. Check the emulator/device connection and Firebase setup, then try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'invalid-credential':
        return 'That account request could not be completed. Please verify your details and try again.';
      default:
        return e.message ?? 'Could not create account. Please try again.';
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    debugPrint('AUTH FLOW >>> create account button tapped');
    setState(() => _submitting = true);

    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
            email: _emailCtrl.text.trim(),
            password: _passwordCtrl.text,
          );
      debugPrint(
        'AUTH FLOW >>> auth success returned source=create-account uid=${credential.user?.uid ?? ''}',
      );
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (!navigator.canPop()) return;
      debugPrint(
        'AUTH FLOW >>> post-auth navigation triggered source=create-account-screen',
      );
      navigator.pop(true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_messageForAuthError(e))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not create account. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Create your account to start building your collection.',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              'Guest mode lets you test scanning and search. Create an account to save cards and track your Pokedex.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.72),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 20),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(labelText: 'Email'),
                    validator: (value) {
                      final email = (value ?? '').trim();
                      if (email.isEmpty) return 'Enter your email.';
                      if (!_looksLikeEmail(email)) {
                        return 'Enter a valid email address.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: const InputDecoration(labelText: 'Password'),
                    validator: (value) {
                      final password = value ?? '';
                      if (password.isEmpty) return 'Enter a password.';
                      if (password.length < 6) {
                        return 'Password must be at least 6 characters.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirmPasswordCtrl,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(
                      labelText: 'Confirm password',
                    ),
                    validator: (value) {
                      final confirmPassword = value ?? '';
                      if (confirmPassword.isEmpty) {
                        return 'Confirm your password.';
                      }
                      if (confirmPassword != _passwordCtrl.text) {
                        return 'Passwords do not match.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Create account'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _submitting = false;

  bool _looksLikeEmail(String value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
  }

  String _messageForAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'user-not-found':
        return 'No account was found for that email.';
      case 'wrong-password':
        return 'Incorrect password.';
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is not enabled in Firebase Auth yet.';
      case 'network-request-failed':
        return 'Network error while signing in. Check the emulator/device connection and Firebase setup, then try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again shortly.';
      default:
        return e.message ?? 'Could not sign in. Please try again.';
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    debugPrint('AUTH FLOW >>> sign-in button tapped');
    setState(() => _submitting = true);

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
      debugPrint(
        'AUTH FLOW >>> auth success returned source=sign-in uid=${credential.user?.uid ?? ''}',
      );
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (!navigator.canPop()) return;
      debugPrint(
        'AUTH FLOW >>> post-auth navigation triggered source=sign-in-screen',
      );
      navigator.pop(true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_messageForAuthError(e))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not sign in. Please try again.')),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Sign in to your collection.',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              'Use your existing account to restore collection access and keep saving cards.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.72),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 20),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: 'Email'),
                    validator: (value) {
                      final email = (value ?? '').trim();
                      if (email.isEmpty) return 'Enter your email.';
                      if (!_looksLikeEmail(email)) {
                        return 'Enter a valid email address.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: 'Password'),
                    validator: (value) {
                      final password = value ?? '';
                      if (password.isEmpty) return 'Enter your password.';
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await Hive.initFlutter();

  await PokemonTcgApi.initCache();
  final initialUser = FirebaseAuth.instance.currentUser;
  debugPrint(
    'AUTH FLOW >>> startup auth init uid=${initialUser?.uid ?? ''} anonymous=${initialUser?.isAnonymous ?? false}',
  );
  try {
    await collectionStore.handleAuthUserChanged(initialUser);
  } catch (e, st) {
    debugPrint('AUTH FLOW >>> startup auth init failed: $e');
    debugPrintStack(stackTrace: st);
  }

  final api = PokemonTcgApi();
  unawaited(api.debugHealthCheck());

  final cameras = await availableCameras();
  gCameras = cameras;
  runApp(CardScanApp(cameras: cameras));
}

enum CardType { pokemon, sports }

extension CardTypeLabel on CardType {
  String get label => this == CardType.pokemon ? 'Pokémon' : 'Sports';
}

// Shared grayscale matrix (keep for PokÃ©dex + missing tiles ONLY)
const List<double> kGreyMatrix = <double>[
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
];

class CardScanApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const CardScanApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Stack(
          children: [if (child != null) child, const RewardOverlayHost()],
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1220),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1220),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(color: Color(0xFF111A2E)),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF111A2E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: AppShell(cameras: cameras),
    );
  }
}

class AppShell extends StatefulWidget {
  final List<CameraDescription> cameras;
  const AppShell({super.key, required this.cameras});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  late final StreamSubscription<User?> _authSubscription;

  Future<void> _handleAuthChange(User? user) async {
    if (!mounted) return;
    debugPrint(
      'AUTH FLOW >>> auth listener fired uid=${user?.uid ?? ''} anonymous=${user?.isAnonymous ?? false}',
    );
    try {
      await collectionStore.handleAuthUserChanged(user);
    } catch (e, st) {
      debugPrint('AUTH FLOW >>> auth listener error: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  @override
  void initState() {
    super.initState();
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
      (user) {
        if (!mounted) return;
        unawaited(_handleAuthChange(user));
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('AUTH FLOW >>> auth listener stream error: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      HomeScreen(cameras: widget.cameras),
      const CollectionScreen(),
      const ProfileScreen(), // âœ… NEW
      const SettingsScreen(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: AnimatedBackground()),
          IndexedStack(index: _index, children: tabs),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            label: 'Collection',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Profile',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, authSnapshot) {
        final user = authSnapshot.data;
        if (user == null || user.isAnonymous) {
          return Scaffold(
            appBar: AppBar(title: const Text('Trainer Profile')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF17325B), Color(0xFF0D1629)],
                      ),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.10),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.14),
                            ),
                          ),
                          child: const Icon(
                            Icons.lock_outline_rounded,
                            size: 34,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'Profile locked',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Create an account to save your collection, track streaks, earn achievements, and sync across devices.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            height: 1.4,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withOpacity(0.78),
                          ),
                        ),
                        const SizedBox(height: 22),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: FilledButton(
                            onPressed: () => _startCreateAccountFlow(context),
                            child: const Text('Create account'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: OutlinedButton(
                            onPressed: () => _startSignInFlow(context),
                            child: const Text('Sign in'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return AnimatedBuilder(
          animation: collectionStore.profileViewVersion,
          builder: (context, _) {
            final level = collectionStore.level;
            final progress = collectionStore.levelProgress.clamp(0.0, 1.0);
            final xpInto = collectionStore.xpIntoLevel;
            final totalXp = collectionStore.totalXp;
            final streak = collectionStore.streak;
            final scans = collectionStore.totalScans;
            final cardsOwned = collectionStore.uniqueRegisteredCount;
            final estValue = collectionStore.totalMarketValue;
            final missingMarketValueCount =
                collectionStore.missingMarketValueCardCount;
            final allMarketValuesRefreshed =
                collectionStore.allMarketValuesRefreshed;
            final recentItems = collectionStore.recentUniqueItems(limit: 4);
            final summaries = collectionStore.getSetSummariesView();
            final unlockedAchievements = collectionStore.unlockedAchievements;
            final knownTotalSlots = summaries.fold<int>(
              0,
              (sum, s) =>
                  sum +
                  ((s.printedTotal != null && s.printedTotal! > 0)
                      ? s.printedTotal!
                      : 0),
            );
            final ownedRegisteredSlots = summaries.fold<int>(
              0,
              (sum, s) => sum + s.ownedUniqueSlots,
            );
            final estimatedProgressValue = knownTotalSlots > 0
                ? (ownedRegisteredSlots / knownTotalSlots).clamp(0.0, 1.0)
                : (cardsOwned / 50).clamp(0.0, 1.0);
            final progressPercent = (estimatedProgressValue * 100).round();
            final hasDuplicateCard = collectionStore.hasDuplicateCard;
            final startedSetCount = collectionStore.startedSetCount;
            final completedSetCount = collectionStore.completedSetCount;
            final bestSetProgressPercent =
                (collectionStore.bestSetProgress * 100).round();
            final hasHighValueCard = collectionStore.hasHighValueCard;
            final achievementCards = <_ProfileAchievementData>[
              _ProfileAchievementData(
                id: CollectionStore.achievementFirstScan,
                title: 'First Card Registered',
                tileLabel: 'First Card',
                subtitle: scans > 0
                    ? 'Your collection has begun'
                    : 'Save your first card',
                icon: Icons.style_outlined,
                progress: scans > 0 ? 1 : 0,
                tier: _AchievementVisualTier.bronze,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementFirstScan,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementScan10,
                title: '5 Cards Registered',
                tileLabel: '5 Cards',
                subtitle: '$scans / 5 cards registered',
                icon: Icons.collections_bookmark_outlined,
                progress: (scans / 5).clamp(0.0, 1.0),
                tier: _AchievementVisualTier.bronze,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementScan10,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementScan25,
                title: '25 Cards Registered',
                tileLabel: '25 Cards',
                subtitle: '$scans / 25 cards registered',
                icon: Icons.library_books_outlined,
                progress: (scans / 25).clamp(0.0, 1.0),
                tier: _AchievementVisualTier.gold,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementScan25,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementFirstUnique,
                title: 'First Pokedex Slot Filled',
                tileLabel: 'First Slot',
                subtitle: ownedRegisteredSlots > 0
                    ? 'Your first slot is registered'
                    : 'Fill your first Pokedex slot',
                icon: Icons.grid_view_rounded,
                progress: ownedRegisteredSlots > 0 ? 1 : 0,
                tier: _AchievementVisualTier.bronze,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementFirstUnique,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementUnique10,
                title: '10 Pokedex Slots Filled',
                tileLabel: '10 Slots',
                subtitle: '$ownedRegisteredSlots / 10 Pokedex slots filled',
                icon: Icons.apps_rounded,
                progress: (ownedRegisteredSlots / 10).clamp(0.0, 1.0),
                tier: _AchievementVisualTier.silver,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementUnique10,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementFirstDuplicate,
                title: 'First Duplicate',
                tileLabel: 'Duplicate',
                subtitle: hasDuplicateCard
                    ? 'Second copy secured'
                    : 'Register a second copy of any card',
                icon: Icons.copy_all_outlined,
                progress: hasDuplicateCard ? 1 : (scans / 2).clamp(0.0, 1.0),
                tier: _AchievementVisualTier.bronze,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementFirstDuplicate,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementSetStarted,
                title: 'First Set Started',
                tileLabel: 'Start Set',
                subtitle: startedSetCount > 0
                    ? '$startedSetCount set${startedSetCount == 1 ? '' : 's'} underway'
                    : 'Register a card from any set',
                icon: Icons.view_module_outlined,
                progress: startedSetCount > 0 ? 1 : 0,
                tier: _AchievementVisualTier.bronze,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementSetStarted,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementSet25,
                title: 'First Set at 25%',
                tileLabel: 'Set 25%',
                subtitle: '$bestSetProgressPercent% / 25% best set progress',
                icon: Icons.donut_small_outlined,
                progress: (collectionStore.bestSetProgress / 0.25).clamp(
                  0.0,
                  1.0,
                ),
                tier: _AchievementVisualTier.silver,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementSet25,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementSet50,
                title: 'First Set at 50%',
                tileLabel: 'Set 50%',
                subtitle: '$bestSetProgressPercent% / 50% best set progress',
                icon: Icons.pie_chart_outline_rounded,
                progress: (collectionStore.bestSetProgress / 0.50).clamp(
                  0.0,
                  1.0,
                ),
                tier: _AchievementVisualTier.gold,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementSet50,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementSetComplete,
                title: 'First Set Completed',
                tileLabel: 'Set Complete',
                subtitle: completedSetCount > 0
                    ? '$completedSetCount set${completedSetCount == 1 ? '' : 's'} completed'
                    : '$bestSetProgressPercent% best set progress',
                icon: Icons.emoji_events_outlined,
                progress: completedSetCount > 0
                    ? 1
                    : collectionStore.bestSetProgress.clamp(0.0, 1.0),
                tier: _AchievementVisualTier.gold,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementSetComplete,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementStreak3,
                title: '3-Day Scan Streak',
                tileLabel: '3-Day',
                subtitle: '$streak / 3 days in a row',
                icon: Icons.whatshot_outlined,
                progress: (streak / 3).clamp(0.0, 1.0),
                tier: _AchievementVisualTier.silver,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementStreak3,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementStreak7,
                title: '7-Day Scan Streak',
                tileLabel: '7-Day',
                subtitle: '$streak / 7 days in a row',
                icon: Icons.local_fire_department_outlined,
                progress: (streak / 7).clamp(0.0, 1.0),
                tier: _AchievementVisualTier.gold,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementStreak7,
                ),
              ),
              _ProfileAchievementData(
                id: CollectionStore.achievementHighValue,
                title: 'First \$20+ Card',
                tileLabel: '\$20+ Card',
                subtitle: hasHighValueCard
                    ? '\$20+ card registered'
                    : 'Register a card worth \$20 or more',
                icon: Icons.attach_money_rounded,
                progress: hasHighValueCard ? 1 : 0,
                tier: _AchievementVisualTier.gold,
                unlocked: unlockedAchievements.contains(
                  CollectionStore.achievementHighValue,
                ),
              ),
            ];

            return Scaffold(
              appBar: AppBar(title: const Text('Trainer Profile')),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF17325B), Color(0xFF0D1629)],
                      ),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.22),
                          blurRadius: 22,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withOpacity(0.10),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.14),
                                ),
                              ),
                              child: const Icon(
                                Icons.catching_pokemon,
                                size: 34,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'TRAINER PROFILE',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.4,
                                      color: Colors.white.withOpacity(0.72),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Trainer Profile',
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w900,
                                      height: 1.0,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Level $level • $streak day streak',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white.withOpacity(0.8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '$totalXp XP',
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w900,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '$xpInto / 500 XP toward Level ${level + 1}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.white.withOpacity(0.78),
                          ),
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 12,
                            backgroundColor: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _ProfileMiniStat(
                                label: 'Streak',
                                value: '$streak',
                                accent: const Color(0xFFF59E0B),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _ProfileMiniStat(
                                label: 'Scans',
                                value: '$scans',
                                accent: const Color(0xFF38BDF8),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.08),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                user == null
                                    ? Icons.person_outline
                                    : Icons.verified_user_outlined,
                                size: 18,
                                color: Colors.white.withOpacity(0.82),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _accountStatusTitle(user),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      user == null
                                          ? 'Guest testing only.'
                                          : _accountIdentifier(user),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white.withOpacity(0.72),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _accountOwnershipExplanation(user),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        height: 1.35,
                                        color: Colors.white.withOpacity(0.62),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _buildAccountActionButtons(context, user),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _ProfileSectionTitle(
                    title: 'Collection Progress',
                    subtitle:
                        'Your Pokédex journey across scanned cards and set slots.',
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      color: const Color(0xFF111A2E),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Cards Owned',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '$cardsOwned',
                                    style: const TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.w900,
                                      height: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    '$progressPercent%',
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    knownTotalSlots > 0
                                        ? 'registered'
                                        : 'estimate',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white.withOpacity(0.68),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          knownTotalSlots > 0
                              ? '$ownedRegisteredSlots / $knownTotalSlots known set slots filled'
                              : 'Using a safe milestone estimate until more full set totals are known.',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.white.withOpacity(0.78),
                          ),
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: estimatedProgressValue,
                            minHeight: 12,
                            backgroundColor: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: _ProfileMiniStat(
                                label: 'Collection Value',
                                value: '\$${estValue.toStringAsFixed(0)}',
                                accent: const Color(0xFF34D399),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _ProfileMiniStat(
                                label: 'Sets Tracked',
                                value: '${summaries.length}',
                                accent: const Color(0xFFA78BFA),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed:
                                collectionStore.marketValueRefreshInProgress
                                ? null
                                : () async {
                                    final beforeMissing = collectionStore
                                        .missingMarketValueCardCount;
                                    collectionStore.configureMarketValueRefresh(
                                      queryBuilder: (card) => buildEbayQuery(
                                        name: card.name,
                                        setName: card.setName,
                                        number: card.number,
                                        printedTotal: card.setPrintedTotal,
                                        mode: EbayMode.raw,
                                      ),
                                      fetcher: fetchEbayMarketValue,
                                    );

                                    final refreshed = await collectionStore
                                        .refreshMissingMarketValues(limit: 5);
                                    final afterMissing = collectionStore
                                        .missingMarketValueCardCount;

                                    if (!context.mounted) return;
                                    final message = afterMissing == 0
                                        ? (beforeMissing > 0
                                              ? 'Updated $refreshed card${refreshed == 1 ? '' : 's'}. All market values refreshed.'
                                              : 'All market values are already refreshed.')
                                        : refreshed > 0
                                        ? 'Updated $refreshed card${refreshed == 1 ? '' : 's'}. $afterMissing still missing values.'
                                        : 'No missing market values were updated. $afterMissing still missing values.';
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(message)),
                                    );
                                  },
                            icon: collectionStore.marketValueRefreshInProgress
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded, size: 16),
                            label: Text(
                              collectionStore.marketValueRefreshInProgress
                                  ? 'Refreshing market values...'
                                  : 'Refresh market values',
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF7DD3FC),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 2,
                              ),
                            ),
                          ),
                        ),
                        if (missingMarketValueCount > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            missingMarketValueCount == 1
                                ? '1 card is still missing a market value.'
                                : '$missingMarketValueCount cards are still missing market values.',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withOpacity(0.68),
                            ),
                          ),
                        ] else if (allMarketValuesRefreshed) ...[
                          const SizedBox(height: 4),
                          Text(
                            'All market values are refreshed.',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF86EFAC).withOpacity(0.82),
                            ),
                          ),
                        ],
                        if (kDebugMode) ...[
                          const SizedBox(height: 12),
                          Text(
                            collectionStore.cloudSyncComplete
                                ? 'Cloud sync complete'
                                : 'Cloud sync pending',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Colors.white70),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _ProfileSectionTitle(
                    title: 'Recently Collected',
                    subtitle: 'Your latest captures, fresh from the scanner.',
                  ),
                  const SizedBox(height: 10),
                  if (recentItems.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: const Color(0xFF111A2E),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Text(
                        'No recent cards yet. Scan a card to start building your trainer story.',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.74),
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: 188,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: recentItems.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          return _RecentCollectedCard(
                            entry: recentItems[index],
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 18),
                  const _ProfileSectionTitle(
                    title: 'Achievements',
                    subtitle:
                        'Milestones for your binder, sets, and collecting streaks.',
                  ),
                  const SizedBox(height: 10),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 0.88,
                        ),
                    itemCount: achievementCards.length,
                    itemBuilder: (context, index) {
                      return _AchievementTile(data: achievementCards[index]);
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _ProfileSectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;

  const _ProfileSectionTitle({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            color: Colors.white.withOpacity(0.72),
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _ProfileMiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  const _ProfileMiniStat({
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentCollectedCard extends StatelessWidget {
  final CollectionEntry entry;

  const _RecentCollectedCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final imageUrl = entry.card.imageSmall.isNotEmpty
        ? entry.card.imageSmall
        : entry.card.imageLarge;

    return Container(
      width: 138,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: const Color(0xFF111A2E),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: imageUrl.isEmpty
                  ? Container(
                      color: Colors.white.withOpacity(0.05),
                      child: const Center(
                        child: Icon(
                          Icons.style_outlined,
                          color: Colors.white54,
                        ),
                      ),
                    )
                  : Image.network(
                      imageUrl,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            entry.card.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(
            entry.card.setName.isNotEmpty
                ? '${entry.card.setName} - #${entry.card.number}'
                : '#${entry.card.number}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withOpacity(0.68),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileAchievementData {
  final String id;
  final String title;
  final String tileLabel;
  final String subtitle;
  final IconData icon;
  final bool unlocked;
  final double progress;
  final _AchievementVisualTier tier;

  const _ProfileAchievementData({
    required this.id,
    required this.title,
    required this.tileLabel,
    required this.subtitle,
    required this.icon,
    required this.unlocked,
    required this.progress,
    required this.tier,
  });
}

enum _AchievementVisualTier { bronze, silver, gold }

class _AchievementVisualSpec {
  final IconData icon;
  final _AchievementVisualTier tier;

  const _AchievementVisualSpec({required this.icon, required this.tier});
}

_AchievementVisualSpec _achievementVisualSpecForId(String id) {
  switch (id) {
    case CollectionStore.achievementFirstScan:
      return const _AchievementVisualSpec(
        icon: Icons.style_outlined,
        tier: _AchievementVisualTier.bronze,
      );
    case CollectionStore.achievementScan10:
      return const _AchievementVisualSpec(
        icon: Icons.collections_bookmark_outlined,
        tier: _AchievementVisualTier.bronze,
      );
    case CollectionStore.achievementScan25:
      return const _AchievementVisualSpec(
        icon: Icons.library_books_outlined,
        tier: _AchievementVisualTier.gold,
      );
    case CollectionStore.achievementFirstUnique:
      return const _AchievementVisualSpec(
        icon: Icons.grid_view_rounded,
        tier: _AchievementVisualTier.bronze,
      );
    case CollectionStore.achievementUnique10:
      return const _AchievementVisualSpec(
        icon: Icons.apps_rounded,
        tier: _AchievementVisualTier.silver,
      );
    case CollectionStore.achievementFirstDuplicate:
      return const _AchievementVisualSpec(
        icon: Icons.copy_all_outlined,
        tier: _AchievementVisualTier.bronze,
      );
    case CollectionStore.achievementSetStarted:
      return const _AchievementVisualSpec(
        icon: Icons.view_module_outlined,
        tier: _AchievementVisualTier.bronze,
      );
    case CollectionStore.achievementSet25:
      return const _AchievementVisualSpec(
        icon: Icons.donut_small_outlined,
        tier: _AchievementVisualTier.silver,
      );
    case CollectionStore.achievementSet50:
      return const _AchievementVisualSpec(
        icon: Icons.pie_chart_outline_rounded,
        tier: _AchievementVisualTier.gold,
      );
    case CollectionStore.achievementSetComplete:
      return const _AchievementVisualSpec(
        icon: Icons.emoji_events_outlined,
        tier: _AchievementVisualTier.gold,
      );
    case CollectionStore.achievementStreak3:
      return const _AchievementVisualSpec(
        icon: Icons.whatshot_outlined,
        tier: _AchievementVisualTier.silver,
      );
    case CollectionStore.achievementStreak7:
      return const _AchievementVisualSpec(
        icon: Icons.local_fire_department_outlined,
        tier: _AchievementVisualTier.gold,
      );
    case CollectionStore.achievementHighValue:
      return const _AchievementVisualSpec(
        icon: Icons.attach_money_rounded,
        tier: _AchievementVisualTier.gold,
      );
    default:
      return const _AchievementVisualSpec(
        icon: Icons.workspace_premium_rounded,
        tier: _AchievementVisualTier.bronze,
      );
  }
}

String? _achievementDescriptionForId(String id) {
  switch (id) {
    case CollectionStore.achievementFirstScan:
      return 'Your collection journey has officially started.';
    case CollectionStore.achievementScan10:
      return 'You are building real scanning momentum.';
    case CollectionStore.achievementScan25:
      return 'Your binder is starting to look serious.';
    case CollectionStore.achievementFirstUnique:
      return 'A brand new card joins your collection.';
    case CollectionStore.achievementUnique10:
      return 'Ten unique cards collected and counting.';
    case CollectionStore.achievementFirstDuplicate:
      return 'You found your first duplicate pull.';
    case CollectionStore.achievementSetStarted:
      return 'A set is now on its way to completion.';
    case CollectionStore.achievementSet25:
      return 'You are a quarter of the way through a set.';
    case CollectionStore.achievementSet50:
      return 'Halfway there. The finish line is in sight.';
    case CollectionStore.achievementSetComplete:
      return 'A full set is complete. Huge collector moment.';
    case CollectionStore.achievementStreak3:
      return 'Three straight days of collection progress.';
    case CollectionStore.achievementStreak7:
      return 'A full week streak. Momentum locked in.';
    case CollectionStore.achievementHighValue:
      return 'You found a card with standout market value.';
    default:
      return null;
  }
}

_AchievementPalette _achievementPaletteFor({
  required bool unlocked,
  required _AchievementVisualTier tier,
  required double progress,
}) {
  if (!unlocked) {
    return const _AchievementPalette(
      medal: [Color(0xFF414857), Color(0xFF252B38)],
      surface: Color(0x0D161D2C),
      ring: Color(0xFF5D6676),
      track: Color(0x1A5D6676),
      icon: Color(0xFF9CA3AF),
      glow: Color(0xFF9CA3AF),
    );
  }

  switch (tier) {
    case _AchievementVisualTier.bronze:
      return const _AchievementPalette(
        medal: [Color(0xFFF5B97A), Color(0xFF9B5D2E)],
        surface: Color(0x12E8A06B),
        ring: Color(0xFFE8A06B),
        track: Color(0x33E8A06B),
        icon: Color(0xFFFFF3E6),
        glow: Color(0xFFE8A06B),
      );
    case _AchievementVisualTier.silver:
      if (progress >= 1) {
        return const _AchievementPalette(
          medal: [Color(0xFFF3F6FA), Color(0xFF9AA6B8)],
          surface: Color(0x12C7D2DF),
          ring: Color(0xFFC7D2DF),
          track: Color(0x33C7D2DF),
          icon: Color(0xFFFFFFFF),
          glow: Color(0xFFC7D2DF),
        );
      }
      return const _AchievementPalette(
        medal: [Color(0xFFDCE3ED), Color(0xFF7F8CA0)],
        surface: Color(0x12AFBCCB),
        ring: Color(0xFFAFBCCB),
        track: Color(0x33AFBCCB),
        icon: Color(0xFFF8FAFC),
        glow: Color(0xFFAFBCCB),
      );
    case _AchievementVisualTier.gold:
      if (progress >= 1) {
        return const _AchievementPalette(
          medal: [Color(0xFFFFF1A8), Color(0xFFF2B938)],
          surface: Color(0x14F5C84C),
          ring: Color(0xFFF5C84C),
          track: Color(0x33F5C84C),
          icon: Color(0xFFFFFFFF),
          glow: Color(0xFFF5C84C),
        );
      }
      return const _AchievementPalette(
        medal: [Color(0xFFF6D97A), Color(0xFFB78925)],
        surface: Color(0x12D9B455),
        ring: Color(0xFFD9B455),
        track: Color(0x33D9B455),
        icon: Color(0xFFFFF8E1),
        glow: Color(0xFFD9B455),
      );
  }
}

class _AchievementTile extends StatelessWidget {
  final _ProfileAchievementData data;

  const _AchievementTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final progress = data.progress.clamp(0.0, 1.0);
    final palette = _achievementPaletteFor(
      unlocked: data.unlocked,
      tier: data.tier,
      progress: progress,
    );
    final foreground = data.unlocked
        ? Colors.white
        : Colors.white.withOpacity(0.58);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () async {
          await showDialog<void>(
            context: context,
            builder: (context) {
              return Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 24,
                ),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF15213B), Color(0xFF0A101C)],
                    ),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                    boxShadow: [
                      BoxShadow(
                        color: palette.glow.withOpacity(0.16),
                        blurRadius: 28,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _AchievementMedal(
                        palette: palette,
                        progress: progress,
                        unlocked: data.unlocked,
                        icon: data.icon,
                        size: 108,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        data.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        data.subtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.72),
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: palette.surface,
                          border: Border.all(color: palette.track),
                        ),
                        child: Text(
                          data.unlocked
                              ? 'Unlocked'
                              : '${(progress * 100).round()}% progress',
                          style: TextStyle(
                            color: palette.icon,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
        child: Ink(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _AchievementMedal(
                palette: palette,
                progress: progress,
                unlocked: data.unlocked,
                icon: data.icon,
                size: 82,
              ),
              const SizedBox(height: 6),
              Text(
                data.tileLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AchievementMedal extends StatelessWidget {
  final _AchievementPalette palette;
  final double progress;
  final bool unlocked;
  final IconData icon;
  final double size;

  const _AchievementMedal({
    required this.palette,
    required this.progress,
    required this.unlocked,
    required this.icon,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final clampedProgress = progress.clamp(0.0, 1.0);
    final medalSize = size * 0.68;
    final iconSize = size * 0.29;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(0, -0.08),
                  radius: 0.78,
                  colors: [
                    palette.glow.withOpacity(unlocked ? 0.28 : 0.03),
                    palette.surface,
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          SizedBox(
            width: size,
            height: size,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: clampedProgress),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) {
                return CircularProgressIndicator(
                  value: value,
                  strokeWidth: size * 0.05,
                  backgroundColor: palette.track,
                  valueColor: AlwaysStoppedAnimation<Color>(palette.ring),
                );
              },
            ),
          ),
          Container(
            width: medalSize,
            height: medalSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.22, -0.24),
                radius: 0.94,
                colors: palette.medal,
              ),
              border: Border.all(
                color: palette.ring.withOpacity(unlocked ? 0.95 : 0.72),
                width: 1.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: palette.glow.withOpacity(unlocked ? 0.28 : 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: medalSize * 0.16,
                  child: Container(
                    width: medalSize * 0.32,
                    height: medalSize * 0.12,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: Colors.white.withOpacity(unlocked ? 0.26 : 0.08),
                    ),
                  ),
                ),
                Icon(
                  Icons.workspace_premium_rounded,
                  color: Colors.white.withOpacity(unlocked ? 0.12 : 0.06),
                  size: medalSize * 0.76,
                ),
                Icon(icon, color: palette.icon, size: iconSize),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AchievementCelebrationBanner extends StatelessWidget {
  final String title;
  final String? description;
  final IconData icon;
  final _AchievementPalette entryPalette;
  final _AchievementPalette finalPalette;
  final Animation<double> medalScale;
  final Animation<double> medalTurn;
  final Animation<double> glow;
  final Animation<double> tierResolve;

  const _AchievementCelebrationBanner({
    required this.title,
    this.description,
    required this.icon,
    required this.entryPalette,
    required this.finalPalette,
    required this.medalScale,
    required this.medalTurn,
    required this.glow,
    required this.tierResolve,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: AnimatedBuilder(
        animation: Listenable.merge([medalScale, medalTurn, glow, tierResolve]),
        builder: (context, _) {
          final palette = _lerpAchievementPalette(
            entryPalette,
            finalPalette,
            tierResolve.value,
          );
          return Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF16213A), Color(0xFF0B111C)],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
              boxShadow: [
                BoxShadow(
                  color: palette.glow.withOpacity(0.34 * glow.value),
                  blurRadius: 42,
                  spreadRadius: 1.5 * glow.value,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 170,
                  height: 170,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 164,
                        height: 164,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              palette.glow.withOpacity(0.34 * glow.value),
                              palette.glow.withOpacity(0.12 * glow.value),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.58, 1.0],
                          ),
                        ),
                      ),
                      Transform.rotate(
                        angle: medalTurn.value,
                        child: Transform.scale(
                          scale: medalScale.value,
                          child: _AchievementMedal(
                            palette: palette,
                            progress: 1,
                            unlocked: true,
                            icon: icon,
                            size: 128,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  'Achievement unlocked',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.icon.withOpacity(0.9),
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    height: 1.06,
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.76),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.32,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AchievementPalette {
  final List<Color> medal;
  final Color surface;
  final Color ring;
  final Color track;
  final Color icon;
  final Color glow;

  const _AchievementPalette({
    required this.medal,
    required this.surface,
    required this.ring,
    required this.track,
    required this.icon,
    required this.glow,
  });
}

class _RewardOverlayGate extends ChangeNotifier {
  int _holdCount = 0;

  bool get isHeld => _holdCount > 0;

  void hold() {
    _holdCount += 1;
    notifyListeners();
  }

  void release() {
    if (_holdCount == 0) return;
    _holdCount -= 1;
    notifyListeners();
  }
}

final _rewardOverlayGate = _RewardOverlayGate();

enum _QueuedRewardKind { xp, achievement, pokedex }

class _QueuedReward {
  final int id;
  final _QueuedRewardKind kind;
  final XpEvent? xpEvent;
  final AchievementEvent? achievementEvent;
  final PokedexEvent? pokedexEvent;

  const _QueuedReward._({
    required this.id,
    required this.kind,
    this.xpEvent,
    this.achievementEvent,
    this.pokedexEvent,
  });

  factory _QueuedReward.xp(int id, XpEvent event) {
    return _QueuedReward._(id: id, kind: _QueuedRewardKind.xp, xpEvent: event);
  }

  factory _QueuedReward.achievement(int id, AchievementEvent event) {
    return _QueuedReward._(
      id: id,
      kind: _QueuedRewardKind.achievement,
      achievementEvent: event,
    );
  }

  factory _QueuedReward.pokedex(int id, PokedexEvent event) {
    return _QueuedReward._(
      id: id,
      kind: _QueuedRewardKind.pokedex,
      pokedexEvent: event,
    );
  }
}

class RewardOverlayHost extends StatefulWidget {
  const RewardOverlayHost({super.key});

  @override
  State<RewardOverlayHost> createState() => _RewardOverlayHostState();
}

class _RewardOverlayHostState extends State<RewardOverlayHost> {
  final Queue<_QueuedReward> _pendingRewards = Queue<_QueuedReward>();
  _QueuedReward? _activeReward;
  int _nextRewardId = 0;

  @override
  void initState() {
    super.initState();
    collectionStore.lastXpEvent.addListener(_onXpEvent);
    collectionStore.lastAchievementEvent.addListener(_onAchievementEvent);
    collectionStore.lastPokedexEvent.addListener(_onPokedexEvent);
    _rewardOverlayGate.addListener(_onGateChanged);
  }

  void _onXpEvent() {
    final event = collectionStore.lastXpEvent.value;
    if (event == null) return;
    _enqueueReward(_QueuedReward.xp(_nextRewardId++, event));
  }

  void _onAchievementEvent() {
    final event = collectionStore.lastAchievementEvent.value;
    if (event == null) return;
    _enqueueReward(_QueuedReward.achievement(_nextRewardId++, event));
  }

  void _onPokedexEvent() {
    final event = collectionStore.lastPokedexEvent.value;
    if (event == null) return;
    _enqueueReward(_QueuedReward.pokedex(_nextRewardId++, event));
  }

  void _enqueueReward(_QueuedReward reward) {
    if (!mounted) return;
    setState(() {
      _pendingRewards.addLast(reward);
      _activeReward ??= _nextRewardIfAllowed();
    });
  }

  void _finishReward(int rewardId) {
    if (!mounted || _activeReward?.id != rewardId) return;
    setState(() {
      _activeReward = _nextRewardIfAllowed();
    });
  }

  _QueuedReward? _nextRewardIfAllowed() {
    if (_rewardOverlayGate.isHeld || _pendingRewards.isEmpty) return null;
    return _pendingRewards.removeFirst();
  }

  void _onGateChanged() {
    if (!mounted || _rewardOverlayGate.isHeld || _activeReward != null) return;
    if (_pendingRewards.isEmpty) return;
    setState(() {
      _activeReward = _nextRewardIfAllowed();
    });
  }

  @override
  void dispose() {
    collectionStore.lastXpEvent.removeListener(_onXpEvent);
    collectionStore.lastAchievementEvent.removeListener(_onAchievementEvent);
    collectionStore.lastPokedexEvent.removeListener(_onPokedexEvent);
    _rewardOverlayGate.removeListener(_onGateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reward = _activeReward;
    if (reward == null) return const SizedBox.shrink();

    switch (reward.kind) {
      case _QueuedRewardKind.xp:
        return XpOverlay(
          key: ValueKey('xp_${reward.id}'),
          event: reward.xpEvent!,
          onComplete: () => _finishReward(reward.id),
        );
      case _QueuedRewardKind.achievement:
        return AchievementOverlay(
          key: ValueKey('achievement_${reward.id}'),
          event: reward.achievementEvent!,
          onComplete: () => _finishReward(reward.id),
        );
      case _QueuedRewardKind.pokedex:
        return PokedexRegisteredOverlay(
          key: ValueKey('pokedex_${reward.id}'),
          event: reward.pokedexEvent!,
          onComplete: () => _finishReward(reward.id),
        );
    }
  }
}

class XpOverlay extends StatefulWidget {
  final XpEvent event;
  final VoidCallback onComplete;

  const XpOverlay({super.key, required this.event, required this.onComplete});

  @override
  State<XpOverlay> createState() => _XpOverlayState();
}

class _XpOverlayState extends State<XpOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  bool _didComplete = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_didComplete) {
        _didComplete = true;
        widget.onComplete();
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FadeTransition(
        opacity: Tween(begin: 1.0, end: 0.0).animate(_fade),
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 80),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.85),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '+${widget.event.xpGained} XP',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (widget.event.leveledUp)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'LEVEL UP!',
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AchievementOverlay extends StatefulWidget {
  final AchievementEvent event;
  final VoidCallback onComplete;

  const AchievementOverlay({
    super.key,
    required this.event,
    required this.onComplete,
  });

  @override
  State<AchievementOverlay> createState() => _AchievementOverlayState();
}

class _AchievementOverlayState extends State<AchievementOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _backdropFade;
  late final Animation<Offset> _slide;
  late final Animation<double> _bannerScale;
  late final Animation<double> _medalScale;
  late final Animation<double> _medalTurn;
  late final Animation<double> _tierResolve;
  late final Animation<double> _glow;
  bool _didComplete = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );

    _fade = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 14,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(1), weight: 60),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 26,
      ),
    ]).animate(_controller);

    _backdropFade = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 0.6,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 12,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(0.6), weight: 58),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.6,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 30,
      ),
    ]).animate(_controller);

    _slide = Tween<Offset>(begin: const Offset(0, -0.18), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.0, 0.24, curve: Curves.easeOutCubic),
          ),
        );

    _bannerScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.94,
          end: 1.015,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 26,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.015,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 74,
      ),
    ]).animate(_controller);

    _medalScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.38,
          end: 1.2,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 28,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.2,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 72,
      ),
    ]).animate(_controller);

    _medalTurn = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: -0.78,
          end: 0.08,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 26,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.08,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 74,
      ),
    ]).animate(_controller);

    _tierResolve = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 14),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 18,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(1), weight: 68),
    ]).animate(_controller);

    _glow = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.16,
          end: 1.26,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 28,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(1.26), weight: 42),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.26,
          end: 0.44,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 30,
      ),
    ]).animate(_controller);

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_didComplete) {
        _didComplete = true;
        widget.onComplete();
      }
    });
    _controller.forward();
  }

  Future<void> _dismissEarly() async {
    if (_controller.status == AnimationStatus.completed) return;
    await _controller.animateTo(
      1.0,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget buildLegacy(BuildContext context) {
    return IgnorePointer(
      child: FadeTransition(
        opacity: _fade,
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 138),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.88),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: const Color(0xFFFF7A00).withOpacity(0.4),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'ðŸ”¥ Achievement Unlocked',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.event.title,
                    style: const TextStyle(
                      color: Color(0xFFFFD166),
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spec = _achievementVisualSpecForId(widget.event.id);
    final description = _achievementDescriptionForId(widget.event.id);
    final finalPalette = _achievementPaletteFor(
      unlocked: true,
      tier: spec.tier,
      progress: 1,
    );
    final entryPalette = _achievementPaletteFor(
      unlocked: true,
      tier: _achievementEntryTierFor(spec.tier),
      progress: 1,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _dismissEarly,
      child: Stack(
        children: [
          Positioned.fill(
            child: FadeTransition(
              opacity: _backdropFade,
              child: Container(color: Colors.black.withOpacity(0.6)),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                child: FadeTransition(
                  opacity: _fade,
                  child: SlideTransition(
                    position: _slide,
                    child: ScaleTransition(
                      scale: _bannerScale,
                      child: _AchievementCelebrationBanner(
                        title: widget.event.title,
                        description: description,
                        icon: spec.icon,
                        entryPalette: entryPalette,
                        finalPalette: finalPalette,
                        medalScale: _medalScale,
                        medalTurn: _medalTurn,
                        glow: _glow,
                        tierResolve: _tierResolve,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

_AchievementVisualTier _achievementEntryTierFor(_AchievementVisualTier tier) {
  switch (tier) {
    case _AchievementVisualTier.bronze:
      return _AchievementVisualTier.bronze;
    case _AchievementVisualTier.silver:
      return _AchievementVisualTier.bronze;
    case _AchievementVisualTier.gold:
      return _AchievementVisualTier.silver;
  }
}

_AchievementPalette _lerpAchievementPalette(
  _AchievementPalette a,
  _AchievementPalette b,
  double t,
) {
  return _AchievementPalette(
    medal: <Color>[
      Color.lerp(a.medal[0], b.medal[0], t)!,
      Color.lerp(a.medal[1], b.medal[1], t)!,
    ],
    surface: Color.lerp(a.surface, b.surface, t)!,
    ring: Color.lerp(a.ring, b.ring, t)!,
    track: Color.lerp(a.track, b.track, t)!,
    icon: Color.lerp(a.icon, b.icon, t)!,
    glow: Color.lerp(a.glow, b.glow, t)!,
  );
}

enum _PostScanReturnKind { home, setPokedex }

class _PostScanReturnTarget {
  final _PostScanReturnKind kind;
  final String? setKey;
  final int? slot;

  const _PostScanReturnTarget.home()
    : kind = _PostScanReturnKind.home,
      setKey = null,
      slot = null;

  const _PostScanReturnTarget.setPokedex({
    required this.setKey,
    required this.slot,
  }) : kind = _PostScanReturnKind.setPokedex;
}

class PostScanOwnedShowcaseScreen extends StatefulWidget {
  final PokemonCardResult card;
  final _PostScanReturnTarget returnTarget;

  const PostScanOwnedShowcaseScreen({
    super.key,
    required this.card,
    required this.returnTarget,
  });

  @override
  State<PostScanOwnedShowcaseScreen> createState() =>
      _PostScanOwnedShowcaseScreenState();
}

class _PostScanOwnedShowcaseScreenState
    extends State<PostScanOwnedShowcaseScreen> {
  bool _exiting = false;

  Future<bool> _handleExit() async {
    if (_exiting || !mounted) return false;
    _exiting = true;

    final route = switch (widget.returnTarget.kind) {
      _PostScanReturnKind.home => MaterialPageRoute(
        builder: (_) => PostScanExitRegistrationAnimationScreen(
          card: widget.card,
          returnTarget: widget.returnTarget,
        ),
      ),
      _PostScanReturnKind.setPokedex => MaterialPageRoute(
        builder: (_) => PostScanExitRegistrationAnimationScreen(
          card: widget.card,
          returnTarget: widget.returnTarget,
        ),
      ),
    };

    Navigator.pushReplacement(context, route);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _handleExit,
      child: OwnedCardShowcaseScreen(card: widget.card),
    );
  }
}

class PostScanExitRegistrationAnimationScreen extends StatefulWidget {
  final PokemonCardResult card;
  final _PostScanReturnTarget returnTarget;

  const PostScanExitRegistrationAnimationScreen({
    super.key,
    required this.card,
    required this.returnTarget,
  });

  @override
  State<PostScanExitRegistrationAnimationScreen> createState() =>
      _PostScanExitRegistrationAnimationScreenState();
}

class _PostScanExitRegistrationAnimationScreenState
    extends State<PostScanExitRegistrationAnimationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _gridReveal;
  late final Animation<double> _cardScale;
  late final Animation<double> _cardTurn;
  late final Animation<double> _slotPulse;
  late final Animation<double> _flash;

  late final String _setKey;
  late final int _targetSlot;

  static const int _gridColumns = 4;
  static const int _visibleSlotCount = 12;

  String get _cardUrl => widget.card.imageLarge.isNotEmpty
      ? widget.card.imageLarge
      : widget.card.imageSmall;

  @override
  void initState() {
    super.initState();

    _setKey = widget.returnTarget.setKey?.trim().isNotEmpty == true
        ? widget.returnTarget.setKey!.trim()
        : widget.card.setId.trim();
    _targetSlot = _resolveTargetSlot();

    collectionStore.setIndexVersion.addListener(_onStoreChanged);
    if (_setKey.isNotEmpty && !collectionStore.hasSetIndex(_setKey)) {
      unawaited(
        collectionStore.ensureSetIndexLoaded(setKey: _setKey, setId: _setKey),
      );
    }

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1750),
    );

    _gridReveal = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.22, curve: Curves.easeOutCubic),
    );

    _cardScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.05,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 18,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.05,
          end: 0.27,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 54,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(0.27), weight: 28),
    ]).animate(_controller);

    _cardTurn = Tween<double>(begin: 0, end: 0.23).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.18, 0.72, curve: Curves.easeInOutCubic),
      ),
    );

    _slotPulse = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 72),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.2,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 12,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.2,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 16,
      ),
    ]).animate(_controller);

    _flash = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 70),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 10,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 20,
      ),
    ]).animate(_controller);

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        _finishExit();
      }
    });

    _controller.forward();
  }

  @override
  void dispose() {
    collectionStore.setIndexVersion.removeListener(_onStoreChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  int _resolveTargetSlot() {
    final explicit = widget.returnTarget.slot;
    if (explicit != null && explicit > 0) return explicit;

    final rawNumber = widget.card.number.trim().toUpperCase();
    final numerator = rawNumber.contains('/')
        ? rawNumber.split('/').first.trim()
        : rawNumber;
    final match = RegExp(r'(\d{1,4})').firstMatch(numerator);
    final parsed = match == null ? null : int.tryParse(match.group(1)!);
    if (parsed != null && parsed > 0) return parsed;
    return 1;
  }

  bool get _hasImpacted => _controller.value >= 0.72;

  int _deriveTotalSlots(
    Map<int, PreviewCard> previewMap,
    Map<int, PokemonCardResult> ownedMap,
  ) {
    var maxSlot = _targetSlot;
    final printedTotal = widget.card.setPrintedTotal;
    if (printedTotal != null && printedTotal > maxSlot) {
      maxSlot = printedTotal;
    }
    for (final slot in previewMap.keys) {
      if (slot > maxSlot) maxSlot = slot;
    }
    for (final slot in ownedMap.keys) {
      if (slot > maxSlot) maxSlot = slot;
    }
    return maxSlot.clamp(1, 9999).toInt();
  }

  List<int> _visibleSlotsForTotal(int totalSlots) {
    final totalVisible = totalSlots < _visibleSlotCount
        ? totalSlots
        : _visibleSlotCount;
    if (totalVisible <= 0) return <int>[_targetSlot];

    final visibleRows = (totalVisible / _gridColumns).ceil();
    final targetRow = (_targetSlot - 1) ~/ _gridColumns;
    var startRow = targetRow - (visibleRows ~/ 2);
    if (startRow < 0) startRow = 0;

    var start = (startRow * _gridColumns) + 1;
    final maxStart = (totalSlots - totalVisible + 1)
        .clamp(1, totalSlots)
        .toInt();
    if (start > maxStart) start = maxStart;
    return List<int>.generate(totalVisible, (index) => start + index);
  }

  Widget _gridSlot({
    required int slot,
    required bool isOwnedBeforeScan,
    required bool isTargetSlot,
    required bool isFilledAfterImpact,
    required PreviewCard? preview,
    required PokemonCardResult? ownedCard,
    required Color accentColor,
  }) {
    final effectiveOwned = isFilledAfterImpact || isOwnedBeforeScan;
    final imageUrl = effectiveOwned
        ? ((ownedCard?.imageSmall.isNotEmpty ?? false)
              ? ownedCard!.imageSmall
              : (ownedCard?.imageLarge ?? ''))
        : ((preview?.imageSmall.isNotEmpty ?? false)
              ? preview!.imageSmall
              : (preview?.imageLarge ?? ''));

    final cardFace = imageUrl.isEmpty
        ? Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.10),
                  Colors.white.withOpacity(0.04),
                ],
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '#$slot',
              style: TextStyle(
                color: Colors.white.withOpacity(0.82),
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          )
        : Image.network(
            imageUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.white.withOpacity(0.06),
              alignment: Alignment.center,
              child: const Icon(Icons.style, size: 20, color: Colors.white70),
            ),
          );

    final displayedFace = effectiveOwned
        ? cardFace
        : ColorFiltered(
            colorFilter: const ColorFilter.matrix(kGreyMatrix),
            child: cardFace,
          );

    final pulseScale = isTargetSlot ? _slotPulse.value : 1.0;
    final flashOpacity = isTargetSlot ? _flash.value : 0.0;

    return Transform.scale(
      scale: pulseScale,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isTargetSlot
                      ? accentColor.withOpacity(effectiveOwned ? 0.9 : 0.45)
                      : Colors.white.withOpacity(0.12),
                  width: isTargetSlot ? 1.8 : 1.0,
                ),
                boxShadow: [
                  if (isTargetSlot)
                    BoxShadow(
                      color: accentColor.withOpacity(
                        0.18 + (0.26 * flashOpacity),
                      ),
                      blurRadius: 18,
                      spreadRadius: 1.2 * flashOpacity,
                    ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: displayedFace,
            ),
          ),
          if (isTargetSlot)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.2),
                      radius: 0.85,
                      colors: [
                        Colors.white.withOpacity(0.34 * flashOpacity),
                        accentColor.withOpacity(0.24 * flashOpacity),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.58),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
              ),
              child: Text(
                '#$slot',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _finishExit() {
    Navigator.popUntil(context, (route) => route.isFirst);
    _rewardOverlayGate.release();
  }

  @override
  Widget build(BuildContext context) {
    final url = _cardUrl.trim();
    final accentColor = cardAccentColor(widget.card);
    final ownedMap = _setKey.isNotEmpty
        ? collectionStore.ownedSlotMapViewForSet(_setKey)
        : const <int, PokemonCardResult>{};
    final previewMap = _setKey.isNotEmpty
        ? collectionStore.previewSlotMapViewForSet(_setKey)
        : const <int, PreviewCard>{};
    final totalSlots = _deriveTotalSlots(previewMap, ownedMap);
    final visibleSlots = _visibleSlotsForTotal(totalSlots);
    final targetPreview = previewMap[_targetSlot];
    final targetPreviewUrl =
        (targetPreview?.imageSmall.isNotEmpty ?? false)
        ? targetPreview!.imageSmall
        : (targetPreview?.imageLarge ?? '');
    final targetIndex = visibleSlots
        .indexOf(_targetSlot)
        .clamp(0, visibleSlots.length - 1)
        .toInt();
    final setName = widget.card.setName.trim().isEmpty
        ? (_setKey.isEmpty ? 'Collection Set' : _setKey.toUpperCase())
        : widget.card.setName;
    final ownedCount = ownedMap.length;

    // ignore: avoid_print
    print(
      'EXIT ANIM target setId="${widget.card.setId}" '
      'setName="$setName" cardNumber="${widget.card.number}" '
      'targetSlot=$_targetSlot',
    );
    // ignore: avoid_print
    print('EXIT ANIM visibleSlots=${visibleSlots.join(',')}');
    // ignore: avoid_print
    print('EXIT ANIM flyingImageUrl present ${url.isNotEmpty}');
    // ignore: avoid_print
    print('EXIT ANIM targetPreviewUrl present ${targetPreviewUrl.isNotEmpty}');

    return Scaffold(
      backgroundColor: const Color(0xFF070A16),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          final maxHeight = constraints.maxHeight;
          final gridWidth = (maxWidth - 40).clamp(280.0, 360.0).toDouble();
          final spacing = 10.0;
          final cellWidth =
              (gridWidth - ((_gridColumns - 1) * spacing)) / _gridColumns;
          const gridRows = 3;
          final gridHeight =
              (cellWidth * 1.42 * gridRows) + (spacing * (gridRows - 1));
          final gridLeft = (maxWidth - gridWidth) / 2;
          final gridTop = maxHeight * 0.46;
          final targetRow = targetIndex ~/ _gridColumns;
          final targetCol = targetIndex % _gridColumns;
          final targetCenter = Offset(
            gridLeft + (targetCol * (cellWidth + spacing)) + (cellWidth / 2),
            gridTop +
                (targetRow * ((cellWidth * 1.42) + spacing)) +
                ((cellWidth * 1.42) / 2),
          );
          final startCenter = Offset(maxWidth / 2, maxHeight * 0.30);
          final flyProgress = Curves.easeInOutCubic.transform(
            ((_controller.value - 0.16) / 0.56).clamp(0.0, 1.0),
          );
          final flyingCenter = Offset.lerp(
            startCenter,
            targetCenter,
            flyProgress,
          )!;
          final cardWidth = cellWidth * 2.35 * _cardScale.value;
          final cardHeight = (cellWidth * 1.42) * 2.35 * _cardScale.value;

          return SafeArea(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              const Color(0xFF130A2A),
                              const Color(0xFF101B42),
                              const Color(0xFF07101E),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: -40,
                      top: 40,
                      child: IgnorePointer(
                        child: Container(
                          width: 220,
                          height: 220,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                accentColor.withOpacity(0.18),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: -30,
                      top: maxHeight * 0.18,
                      child: IgnorePointer(
                        child: Container(
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                const Color(0xFF8B5CF6).withOpacity(0.16),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: 0.07,
                          child: CustomPaint(
                            painter: _CollectionGridPatternPainter(),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 24,
                      right: 24,
                      top: 26,
                      child: Opacity(
                        opacity: _gridReveal.value,
                        child: Column(
                          children: [
                            Text(
                              'Registered to Pokédex',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.96),
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '$setName  •  Slot #$_targetSlot',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.74),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '$ownedCount owned in this set',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.58),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: gridLeft,
                      top: gridTop - 18,
                      child: Opacity(
                        opacity: _gridReveal.value,
                        child: Container(
                          width: gridWidth,
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            color: const Color(0xFF0D1732).withOpacity(0.88),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.10),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.26),
                                blurRadius: 28,
                                offset: const Offset(0, 16),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 11,
                                    height: 11,
                                    decoration: BoxDecoration(
                                      color: accentColor,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: accentColor.withOpacity(0.34),
                                          blurRadius: 12,
                                          spreadRadius: 1,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      setName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: gridWidth - 28,
                                height: gridHeight,
                                child: GridView.builder(
                                  physics: const NeverScrollableScrollPhysics(),
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: _gridColumns,
                                        mainAxisSpacing: 10,
                                        crossAxisSpacing: 10,
                                        childAspectRatio: 0.70,
                                      ),
                                  itemCount: visibleSlots.length,
                                  itemBuilder: (context, index) {
                                    final slot = visibleSlots[index];
                                    final isTarget = slot == _targetSlot;
                                    final ownedCard = ownedMap[slot];
                                    final preview = previewMap[slot];
                                    final ownedBeforeScan =
                                        ownedCard != null && !isTarget;
                                    final filledAfterImpact =
                                        isTarget && _hasImpacted;

                                    return _gridSlot(
                                      slot: slot,
                                      isOwnedBeforeScan: ownedBeforeScan,
                                      isTargetSlot: isTarget,
                                      isFilledAfterImpact: filledAfterImpact,
                                      preview: preview,
                                      ownedCard: isTarget
                                          ? widget.card
                                          : ownedCard,
                                      accentColor: accentColor,
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!_hasImpacted)
                      Positioned(
                        left: flyingCenter.dx - (cardWidth / 2),
                        top: flyingCenter.dy - (cardHeight / 2),
                        child: Transform.rotate(
                          angle: _cardTurn.value,
                          child: Container(
                            width: cardWidth,
                            height: cardHeight,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: [
                                BoxShadow(
                                  color: accentColor.withOpacity(0.24),
                                  blurRadius: 24,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: url.isEmpty
                                  ? Container(
                                      color: const Color(0xFF1F1F1F),
                                      alignment: Alignment.center,
                                      child: const Icon(Icons.style, size: 44),
                                    )
                                  : Image.network(url, fit: BoxFit.cover),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _CollectionGridPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const gap = 36.0;

    for (double x = 0; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PokedexRegisteredOverlay extends StatefulWidget {
  final PokedexEvent event;
  final VoidCallback onComplete;

  const PokedexRegisteredOverlay({
    super.key,
    required this.event,
    required this.onComplete,
  });

  @override
  State<PokedexRegisteredOverlay> createState() =>
      _PokedexRegisteredOverlayState();
}

class _PokedexRegisteredOverlayState extends State<PokedexRegisteredOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  bool _didComplete = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _fade = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 18,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(1), weight: 50),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 32,
      ),
    ]).animate(_controller);

    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.9,
          end: 1.03,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 34,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.03,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 24,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 42),
    ]).animate(_controller);

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_didComplete) {
        _didComplete = true;
        widget.onComplete();
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.event.imageUrl;

    return IgnorePointer(
      child: FadeTransition(
        opacity: _fade,
        child: Center(
          child: ScaleTransition(
            scale: _scale,
            child: Container(
              width: 260,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: const Color(0xFF93C5FD).withOpacity(0.35),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF081427).withOpacity(0.96),
                    const Color(0xFF12213F).withOpacity(0.94),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF60A5FA).withOpacity(0.22),
                    blurRadius: 28,
                    spreadRadius: 3,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (imageUrl.isNotEmpty)
                    Container(
                      width: 92,
                      height: 128,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withOpacity(0.22),
                            const Color(0xFF93C5FD).withOpacity(0.12),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFBFDBFE).withOpacity(0.18),
                            blurRadius: 18,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: Colors.white.withOpacity(0.06),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.auto_awesome,
                              color: Colors.white70,
                              size: 32,
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    Container(
                      width: 92,
                      height: 92,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.08),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.menu_book_rounded,
                        color: Colors.white70,
                        size: 36,
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'Pokédex Registered',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.event.cardName,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFBFDBFE),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, authSnapshot) {
        final user = authSnapshot.data;
        return AnimatedBuilder(
          animation: collectionStore.profileViewVersion,
          builder: (context, _) {
            final missingMarketValueCount =
                collectionStore.missingMarketValueCardCount;
            final accountDetail = user == null
                ? 'Guest testing only.'
                : _accountIdentifier(user);
            final accountExplanation = _accountOwnershipExplanation(user);

            return Scaffold(
              appBar: AppBar(title: const Text('Settings')),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _SettingsSection(
                    title: 'Account',
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            user == null
                                ? Icons.person_outline
                                : Icons.verified_user_outlined,
                            color: Colors.white.withOpacity(0.86),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _accountStatusTitle(user),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                accountDetail,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.72),
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                accountExplanation,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.68),
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _buildAccountActionButtons(context, user),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const _SettingsSection(
                    title: 'Data & Sync',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Your collection works locally on this device.',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'When you are signed in, card data can sync to your cloud account. Some older local or demo data may not automatically move between users.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsSection(
                    title: 'Market Values',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          missingMarketValueCount > 0
                              ? missingMarketValueCount == 1
                                    ? '1 owned card still needs a market value refresh.'
                                    : '$missingMarketValueCount owned cards still need market value refreshes.'
                              : 'All currently owned cards have market values.',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Collection value updates over time as missing card values are refreshed.',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const _SettingsSection(
                    title: 'About',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PokeScan',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Scan cards, register your Pokédex, and build complete sets with confidence.',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _SettingsSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          DefaultTextStyle(
            style: TextStyle(
              color: Colors.white.withOpacity(0.82),
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

// HOME (state) + TILE + SCREEN (all use FeaturedCardData)

class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const HomeScreen({super.key, required this.cameras});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<FeaturedCardData?> _future;

  @override
  void initState() {
    super.initState();
    _reloadFeatured();
  }

  void _reloadFeatured() {
    setState(() {
      _future = FeaturedCardService.getToday();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compactSpacing = constraints.maxHeight < 760;
            final verticalGap = compactSpacing ? 11.0 : 15.0;
            return AnimatedBuilder(
              animation: collectionStore,
              builder: (context, _) {
                final level = collectionStore.level;
                final streak = collectionStore.streak;
                final cards = collectionStore.count;
                final xpInto = collectionStore.xpIntoLevel;
                final xpProgress = collectionStore.levelProgress.clamp(
                  0.0,
                  1.0,
                );
                final nextGoal = _resolveNextGoal();

                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    compactSpacing ? 10 : 14,
                    16,
                    compactSpacing ? 8 : 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              gradient: LinearGradient(
                                colors: [
                                  Colors.white.withOpacity(0.14),
                                  Colors.white.withOpacity(0.05),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.10),
                              ),
                            ),
                            child: const Icon(Icons.style_outlined, size: 21),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'CardScan',
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Scan. Register. Complete.',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          StreamBuilder<User?>(
                            stream: FirebaseAuth.instance.authStateChanges(),
                            initialData: FirebaseAuth.instance.currentUser,
                            builder: (context, snapshot) {
                              final user = snapshot.data;
                              if (user == null || user.isAnonymous) {
                                return ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 150,
                                  ),
                                  child: Wrap(
                                    alignment: WrapAlignment.end,
                                    runSpacing: 6,
                                    spacing: 6,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: () => _handleAuthAction(
                                          context,
                                          user: user,
                                        ),
                                        icon: Icon(
                                          _accountActionIcon(user),
                                          size: 16,
                                        ),
                                        label: Text(_accountActionLabel(user)),
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 10,
                                          ),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            _startCreateAccountFlow(context),
                                        style: FilledButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 10,
                                          ),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text('Create account'),
                                      ),
                                      OutlinedButton(
                                        onPressed: () =>
                                            _startSignInFlow(context),
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 10,
                                          ),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text('Sign in'),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              return OutlinedButton.icon(
                                onPressed: () =>
                                    _handleAuthAction(context, user: user),
                                icon: Icon(_accountActionIcon(user), size: 18),
                                label: Text(_accountActionLabel(user)),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      SizedBox(height: verticalGap),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.90),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                                children: [
                                  TextSpan(text: 'Level $level'),
                                  const TextSpan(text: '  •  '),
                                  TextSpan(text: '$cards cards'),
                                  const TextSpan(text: '  •  '),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Icon(
                                        Icons.local_fire_department,
                                        color: Colors.orange.shade300,
                                        size: 15,
                                      ),
                                    ),
                                  ),
                                  TextSpan(text: '$streak day streak'),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                value: xpProgress,
                                minHeight: 7,
                                backgroundColor: Colors.white.withOpacity(0.07),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.lightBlueAccent.shade100,
                                ),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '$xpInto / 500 XP toward Level ${level + 1}',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.60),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: verticalGap),
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  ScanScreen(cameras: widget.cameras),
                            ),
                          );
                        },
                        child: Ink(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            gradient: const LinearGradient(
                              colors: [Color(0xFF7AE3FF), Color(0xFF3A7BFF)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFF3A7BFF,
                                ).withOpacity(0.34),
                                blurRadius: 24,
                                spreadRadius: -4,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.16),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.18),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.camera_alt_rounded,
                                  color: Colors.white,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Scan your next card',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.98),
                                        fontSize: 20,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      'Fast camera scan for your collection',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.82),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Icon(
                                Icons.arrow_forward_rounded,
                                color: Colors.white,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const ManualSearchScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.search, size: 18),
                          label: const Text('Search manually'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white.withOpacity(0.88),
                            backgroundColor: Colors.white.withOpacity(0.035),
                            side: BorderSide(
                              color: Colors.white.withOpacity(0.14),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            alignment: Alignment.centerLeft,
                          ),
                        ),
                      ),
                      SizedBox(height: verticalGap),
                      Expanded(
                        child: FutureBuilder<FeaturedCardData?>(
                          future: _future,
                          builder: (context, featuredSnap) {
                            final setStrip = _resolveSetInProgressStrip(
                              featured: featuredSnap.data,
                            );
                            final hasSetRoute = setStrip.setKey.isNotEmpty;
                            if (hasSetRoute) {
                              _primeSetInProgressSet(setStrip);
                            }
                            final ownedMap = hasSetRoute
                                ? collectionStore.ownedSlotMapViewForSet(
                                    setStrip.setKey,
                                  )
                                : const <int, PokemonCardResult>{};
                            final previewMap = hasSetRoute
                                ? collectionStore.previewSlotMapViewForSet(
                                    setStrip.setKey,
                                  )
                                : const <int, PreviewCard>{};
                            final stripSlots = _resolveSetInProgressSlots(
                              strip: setStrip,
                              ownedMap: ownedMap,
                              previewMap: previewMap,
                              maxSlots: compactSpacing ? 5 : 6,
                            );

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildSetInProgressStrip(
                                  strip: setStrip,
                                  slots: stripSlots,
                                  compactSpacing: compactSpacing,
                                ),
                                SizedBox(
                                  height: compactSpacing ? 6 : 10,
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 13,
                                    vertical: 11,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.04),
                                    borderRadius: BorderRadius.circular(15),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.06),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 34,
                                        height: 34,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.06),
                                          borderRadius:
                                              BorderRadius.circular(11),
                                        ),
                                        child: const Icon(
                                          Icons.auto_awesome,
                                          color: Colors.white70,
                                          size: 18,
                                        ),
                                      ),
                                      const SizedBox(width: 11),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Next goal',
                                              style: TextStyle(
                                                color: Colors.white.withOpacity(
                                                  0.58,
                                                ),
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.6,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              nextGoal,
                                              style: TextStyle(
                                                color: Colors.white.withOpacity(
                                                  0.90,
                                                ),
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                                height: 1.2,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  height: compactSpacing ? 6 : 10,
                                ),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: _buildHomeFeaturedCard(featuredSnap),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  _HomeSetStripData _resolveSetInProgressStrip({
    required FeaturedCardData? featured,
  }) {
    final summaries = collectionStore.getSetSummariesView();
    SetSummary? bestIncomplete;
    for (final summary in summaries) {
      final printedTotal = summary.printedTotal ?? 0;
      final isIncomplete =
          printedTotal <= 0 || summary.ownedUniqueSlots < printedTotal;
      if (!isIncomplete) continue;
      if (bestIncomplete == null ||
          summary.ownedUniqueSlots > bestIncomplete.ownedUniqueSlots) {
        bestIncomplete = summary;
      }
    }

    final target = bestIncomplete ?? (summaries.isNotEmpty ? summaries.first : null);
    if (target != null) {
      return _HomeSetStripData(
        setKey: target.setKey,
        setName: target.setName,
        printedTotal: target.printedTotal,
        focalSlot: _mostRecentSlotForSet(target.setKey),
        ownedCount: target.ownedUniqueSlots,
      );
    }

    final featuredCard = featured?.card;
    final featuredSetKey = featuredCard?.setId.trim() ?? '';
    final featuredSetName = featuredCard?.setName.trim() ?? '';
    if (featuredSetKey.isNotEmpty && featuredSetName.isNotEmpty) {
      return _HomeSetStripData(
        setKey: featuredSetKey,
        setName: featuredSetName,
        printedTotal: featuredCard?.setPrintedTotal,
        focalSlot: _parseSlotNumber(featuredCard?.number ?? ''),
        ownedCount: 0,
      );
    }

    return const _HomeSetStripData(
      setKey: '',
      setName: 'Your first set',
      printedTotal: 6,
      focalSlot: 1,
      ownedCount: 0,
    );
  }

  int? _mostRecentSlotForSet(String setKey) {
    final entries = collectionStore.itemsForSet(setKey);
    for (final entry in entries) {
      final slot = _parseSlotNumber(entry.card.number);
      if (slot != null) return slot;
    }
    return null;
  }

  int? _parseSlotNumber(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    return int.tryParse(digits);
  }

  void _primeSetInProgressSet(_HomeSetStripData strip) {
    if (strip.setKey.isEmpty || collectionStore.hasSetIndex(strip.setKey)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        collectionStore.ensureSetIndexLoaded(
          setKey: strip.setKey,
          setId: strip.setKey,
        ),
      );
    });
  }

  List<_HomeSetStripSlot> _resolveSetInProgressSlots({
    required _HomeSetStripData strip,
    required Map<int, PokemonCardResult> ownedMap,
    required Map<int, PreviewCard> previewMap,
    required int maxSlots,
  }) {
    final total = _resolveSetInProgressTotal(
      strip: strip,
      ownedMap: ownedMap,
      previewMap: previewMap,
      minimumSlots: maxSlots,
    );
    final window = _resolveSetInProgressWindow(
      total: total,
      ownedSlots: ownedMap.keys.toList()..sort(),
      focalSlot: strip.focalSlot,
      desiredSlots: maxSlots,
    );
    return window
        .map(
          (slot) => _HomeSetStripSlot(
            slot: slot,
            owned: ownedMap[slot],
            preview: previewMap[slot],
          ),
        )
        .toList(growable: false);
  }

  int _resolveSetInProgressTotal({
    required _HomeSetStripData strip,
    required Map<int, PokemonCardResult> ownedMap,
    required Map<int, PreviewCard> previewMap,
    required int minimumSlots,
  }) {
    var total = strip.printedTotal ?? 0;
    for (final slot in ownedMap.keys) {
      if (slot > total) total = slot;
    }
    for (final slot in previewMap.keys) {
      if (slot > total) total = slot;
    }
    final focalSlot = strip.focalSlot ?? 0;
    if (focalSlot > total) total = focalSlot;
    if (total < minimumSlots) total = minimumSlots;
    if (total > 500) return 500;
    return total;
  }

  List<int> _resolveSetInProgressWindow({
    required int total,
    required List<int> ownedSlots,
    required int? focalSlot,
    required int desiredSlots,
  }) {
    final visibleCount = total < desiredSlots ? total : desiredSlots;
    final maxStart = total - visibleCount + 1;
    if (visibleCount <= 0 || maxStart <= 0) return const <int>[];

    if (ownedSlots.isEmpty) {
      var start = (focalSlot ?? 1) - (visibleCount ~/ 2);
      if (start < 1) start = 1;
      if (start > maxStart) start = maxStart;
      return List<int>.generate(visibleCount, (index) => start + index);
    }

    var bestStart = 1;
    var bestOwnedCount = -1;
    var bestDistanceScore = 1 << 30;

    for (var start = 1; start <= maxStart; start++) {
      final end = start + visibleCount - 1;
      final center = start + ((visibleCount - 1) / 2.0);
      var ownedCount = 0;
      var distanceScore = 0;

      for (final slot in ownedSlots) {
        if (slot < start || slot > end) continue;
        ownedCount += 1;
        distanceScore += ((slot - center).abs() * 100).round();
      }

      final shouldTake = ownedCount > bestOwnedCount ||
          (ownedCount == bestOwnedCount &&
              distanceScore < bestDistanceScore);
      if (!shouldTake) continue;
      bestStart = start;
      bestOwnedCount = ownedCount;
      bestDistanceScore = distanceScore;
    }

    return List<int>.generate(visibleCount, (index) => bestStart + index);
  }

  void _openSetInProgress(_HomeSetStripData strip) {
    if (strip.setKey.isEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CollectionScreen()),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: 'set_pokedex'),
        builder: (_) => SetPokedexScreen(
          setKey: strip.setKey,
          setName: strip.setName,
          printedTotal: strip.printedTotal,
        ),
      ),
    );
  }

  void _openSetInProgressSlot({
    required _HomeSetStripData strip,
    required _HomeSetStripSlot slot,
  }) {
    if (strip.setKey.isEmpty) {
      _openSetInProgress(strip);
      return;
    }

    if (slot.owned != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OwnedCardShowcaseScreen(card: slot.owned!),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LockedCardShowcaseScreen(
          slot: slot.slot,
          preview: slot.preview,
          setKey: strip.setKey,
          setName: strip.setName,
        ),
      ),
    );
  }

  Widget _buildSetInProgressStrip({
    required _HomeSetStripData strip,
    required List<_HomeSetStripSlot> slots,
    required bool compactSpacing,
  }) {
    final canOpenSet = strip.setKey.isNotEmpty;
    final progressText = strip.printedTotal != null && strip.printedTotal! > 0
        ? '${strip.ownedCount}/${strip.printedTotal}'
        : '${strip.ownedCount} collected';

    return Container(
      padding: EdgeInsets.fromLTRB(
        14,
        compactSpacing ? 12 : 14,
        14,
        compactSpacing ? 10 : 12,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.045),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _openSetInProgress(strip),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Set in progress',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.62),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.7,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          strip.setName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          progressText,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.68),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _openSetInProgress(strip),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white.withOpacity(0.90),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      canOpenSet ? 'View set' : 'View all',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 2),
                    const Icon(Icons.chevron_right_rounded, size: 18),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: compactSpacing ? 102 : 110,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < slots.length; i++) ...[
                    _buildSetInProgressSlotTile(
                      strip: strip,
                      slot: slots[i],
                      compactSpacing: compactSpacing,
                    ),
                    if (i != slots.length - 1) const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSetInProgressSlotTile({
    required _HomeSetStripData strip,
    required _HomeSetStripSlot slot,
    required bool compactSpacing,
  }) {
    final imageUrl = slot.imageUrl;
    final showImage = imageUrl.startsWith('http://') || imageUrl.startsWith('https://');
    final cardWidth = compactSpacing ? 54.0 : 58.0;
    final cardHeight = compactSpacing ? 76.0 : 82.0;
    final isOwned = slot.owned != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openSetInProgressSlot(strip: strip, slot: slot),
        child: SizedBox(
          width: cardWidth,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                width: cardWidth,
                height: cardHeight,
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: isOwned
                                ? const [
                                    Color(0xFF173158),
                                    Color(0xFF0B1528),
                                  ]
                                : const [
                                    Color(0xFF1B2433),
                                    Color(0xFF111827),
                                  ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withOpacity(
                              isOwned ? 0.14 : 0.08,
                            ),
                          ),
                        ),
                        child: showImage
                            ? _buildSetInProgressSlotImage(
                                imageUrl: imageUrl,
                                isOwned: isOwned,
                              )
                            : _buildSetInProgressSlotPlaceholder(isOwned: isOwned),
                      ),
                    ),
                    if (!isOwned)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: Colors.black.withOpacity(0.28),
                          ),
                        ),
                      ),
                    if (isOwned)
                      Positioned(
                        top: 5,
                        right: 5,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: const Color(0xFF81E6A8),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.24),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            size: 12,
                            color: Color(0xFF112016),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '#${slot.slot}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Colors.white.withOpacity(isOwned ? 0.92 : 0.60),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSetInProgressSlotImage({
    required String imageUrl,
    required bool isOwned,
  }) {
    final image = Image.network(
      imageUrl,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) =>
          _buildSetInProgressSlotPlaceholder(isOwned: isOwned),
    );
    if (isOwned) return image;

    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      child: image,
    );
  }

  Widget _buildSetInProgressSlotPlaceholder({required bool isOwned}) {
    return Center(
      child: Icon(
        isOwned ? Icons.style_outlined : Icons.image_not_supported_outlined,
        size: 22,
        color: Colors.white.withOpacity(isOwned ? 0.76 : 0.42),
      ),
    );
  }

  Widget _buildHomeFeaturedCard(AsyncSnapshot<FeaturedCardData?> snap) {
    if (snap.connectionState != ConnectionState.done) {
      return Container(
        height: 98,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white.withOpacity(0.03),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
      );
    }

    if (snap.hasError) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white.withOpacity(0.03),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, color: Colors.white70, size: 18),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Card of the Day unavailable.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _reloadFeatured,
            ),
          ],
        ),
      );
    }

    final featured = snap.data;
    if (featured == null) return const SizedBox.shrink();
    return _FeaturedHeroCard(featured: featured);
  }

  String _resolveNextGoal() {
    final summaries = collectionStore.getSetSummariesView();
    if (summaries.isEmpty) {
      return 'Add your first card to start building a set.';
    }

    SetSummary? target;
    for (final summary in summaries) {
      final printedTotal = summary.printedTotal ?? 0;
      final hasKnownProgress =
          printedTotal > 0 && summary.ownedUniqueSlots < printedTotal;
      if (!hasKnownProgress) continue;
      if (target == null) {
        target = summary;
        continue;
      }

      final targetScore = target.progress * 1000 + target.ownedUniqueSlots;
      final currentScore = summary.progress * 1000 + summary.ownedUniqueSlots;
      if (currentScore > targetScore) {
        target = summary;
      }
    }

    target ??= summaries.first;
    final printedTotal = target.printedTotal ?? 0;
    if (printedTotal <= 0) {
      return 'Keep building ${target.setName}.';
    }

    final missing = (printedTotal - target.ownedUniqueSlots).clamp(0, 9999);
    if (missing <= 1) {
      return 'Complete ${target.setName} with 1 more card.';
    }

    final addCount = missing.clamp(1, 3).toInt();
    final noun = addCount == 1 ? 'card' : 'cards';
    return 'Add $addCount more $noun to ${target.setName}.';
  }
}

class _HomeSetStripData {
  final String setKey;
  final String setName;
  final int? printedTotal;
  final int? focalSlot;
  final int ownedCount;

  const _HomeSetStripData({
    required this.setKey,
    required this.setName,
    required this.printedTotal,
    required this.focalSlot,
    required this.ownedCount,
  });
}

class _HomeSetStripSlot {
  final int slot;
  final PokemonCardResult? owned;
  final PreviewCard? preview;

  const _HomeSetStripSlot({
    required this.slot,
    required this.owned,
    required this.preview,
  });

  String get imageUrl {
    final ownedImage = owned?.imageSmall ?? owned?.imageLarge ?? '';
    if (ownedImage.trim().isNotEmpty) return ownedImage;
    final previewImage = preview?.imageSmall ?? preview?.imageLarge ?? '';
    return previewImage.trim();
  }
}

class _FeaturedHeroCard extends StatelessWidget {
  final FeaturedCardData featured;
  const _FeaturedHeroCard({required this.featured});

  bool _isHttpUrl(String s) {
    final u = s.trim();
    return u.startsWith('http://') || u.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final c = featured.card;
    final img = c.imageSmall.isNotEmpty ? c.imageSmall : c.imageLarge;
    final hasImg = _isHttpUrl(img);

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CardOfTheDayScreen(featured: featured),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: [const Color(0xFF0A1220), const Color(0xFF10192B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.14),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 50,
                height: 70,
                child: hasImg
                    ? Image.network(
                        img,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _fallbackCardArt(),
                      )
                    : _fallbackCardArt(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white.withOpacity(0.10)),
                    ),
                    child: const Text(
                      'CARD OF THE DAY',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.7,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${c.setName} • #${c.number}',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.64),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(
                        Icons.local_fire_department,
                        size: 12,
                        color: Colors.orangeAccent,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          featured.meta.headline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right_rounded,
              color: Colors.white38,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackCardArt() {
    return Container(
      color: Colors.white.withOpacity(0.06),
      child: const Center(child: Icon(Icons.image_not_supported_outlined)),
    );
  }
}

class _ActionPanelButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool filled;
  final VoidCallback onTap;

  const _ActionPanelButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = filled
        ? Colors.white.withOpacity(0.08)
        : Colors.white.withOpacity(0.03);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 26),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.68),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CardOfTheDayScreen extends StatelessWidget {
  final FeaturedCardData featured;
  const CardOfTheDayScreen({super.key, required this.featured});

  @override
  Widget build(BuildContext context) {
    final c = featured.card;

    return Scaffold(
      appBar: AppBar(title: const Text('Card of the Day')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.06),
                  Colors.white.withOpacity(0.02),
                ],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.30),
                  blurRadius: 24,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: AspectRatio(
                        aspectRatio: 63 / 88,
                        child: PokemonCardShowcase(card: c, animate: true),
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),

                  Text(
                    c.name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${c.setName} - #${c.number}',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.72),
                      fontWeight: FontWeight.w600,
                    ),
                  ),

                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white.withOpacity(0.10)),
                    ),
                    child: Text(
                      featured.meta.headline,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  Text(
                    featured.meta.why,
                    style: TextStyle(
                      height: 1.45,
                      color: Colors.white.withOpacity(0.88),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Text(
              'Card of the Day highlights iconic, trending, or historically significant cards in Pokémon collecting.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.78),
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imgFallbackLarge() {
    return Container(
      color: Colors.white.withOpacity(0.06),
      child: const Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 40,
          color: Colors.white54,
        ),
      ),
    );
  }
}
/* --------------------------- SCAN FLOW (camera) --------------------------- */

class ScanScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final String? expectedSetId;
  final int? expectedSlot;

  const ScanScreen({
    super.key,
    required this.cameras,
    this.expectedSetId,
    this.expectedSlot,
  });

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _controller;
  Future<void>? _initFuture;
  XFile? _captured;
  TextRecognizer? _liveScanRecognizer;
  bool _liveScanEnabled = kEnableLiveScanPrototype;
  bool _liveScanStreaming = false;
  bool _liveScanAnalyzing = false;
  bool _autoCaptureTriggered = false;
  int _stableLiveDetections = 0;
  DateTime? _lastLiveAnalysisAt;
  String _liveScanStatus = 'Looking for card…';

  @override
  void initState() {
    super.initState();
    if (widget.cameras.isEmpty) return;

    _controller = CameraController(
      widget.cameras.first,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    _initFuture = _controller!.initialize().then((_) async {
      if (_liveScanEnabled) {
        _liveScanRecognizer = TextRecognizer(
          script: TextRecognitionScript.latin,
        );
        await _maybeStartLiveScan();
      }
    });
  }

  @override
  void dispose() {
    unawaited(_stopLiveScan());
    if (_liveScanRecognizer != null) {
      unawaited(_liveScanRecognizer!.close());
    }
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _maybeStartLiveScan() async {
    final controller = _controller;
    if (!_liveScanEnabled || controller == null || !mounted) return;
    if (!Platform.isAndroid) {
      _liveScanEnabled = false;
      return;
    }
    if (!controller.value.isInitialized ||
        controller.value.isStreamingImages ||
        _captured != null ||
        _autoCaptureTriggered) {
      return;
    }

    _stableLiveDetections = 0;
    _lastLiveAnalysisAt = null;
    if (mounted) {
      setState(() => _liveScanStatus = 'Looking for card…');
    }

    try {
      await controller.startImageStream((image) {
        unawaited(_handleLiveFrame(image));
      });
      _liveScanStreaming = true;
    } catch (e) {
      debugPrint('LIVE SCAN >>> stream start failed: $e');
      _liveScanEnabled = false;
      _liveScanStreaming = false;
    }
  }

  Future<void> _stopLiveScan() async {
    final controller = _controller;
    if (controller == null || !_liveScanStreaming) return;
    try {
      await controller.stopImageStream();
    } catch (e) {
      debugPrint('LIVE SCAN >>> stream stop failed: $e');
    } finally {
      _liveScanStreaming = false;
      _liveScanAnalyzing = false;
    }
  }

  Future<void> _handleLiveFrame(CameraImage image) async {
    if (!_liveScanEnabled ||
        _autoCaptureTriggered ||
        _captured != null ||
        _liveScanAnalyzing) {
      return;
    }
    if (_stableLiveDetections > 5) {
      return;
    }

    final now = DateTime.now();
    final last = _lastLiveAnalysisAt;
    if (last != null && now.difference(last).inMilliseconds < 1000) {
      return;
    }
    _lastLiveAnalysisAt = now;
    _liveScanAnalyzing = true;

    try {
      final hasSignal = await _detectLiveCardSignal(image);
      if (!_liveScanEnabled || _captured != null || _autoCaptureTriggered) {
        return;
      }

      if (hasSignal) {
        _stableLiveDetections += 1;
        if (!mounted) return;
        setState(() {
          _liveScanStatus = _stableLiveDetections >= 2
              ? 'Card detected'
              : 'Hold steady…';
        });
        if (_stableLiveDetections >= 2) {
          _autoCaptureTriggered = true;
          unawaited(_autoCapturePhoto());
        }
      } else {
        _stableLiveDetections = 0;
        if (!mounted) return;
        setState(() => _liveScanStatus = 'Looking for card…');
      }
    } catch (e) {
      debugPrint('LIVE SCAN >>> frame analysis failed: $e');
      _liveScanEnabled = false;
      await _stopLiveScan();
    } finally {
      _liveScanAnalyzing = false;
    }
  }

  Future<bool> _detectLiveCardSignal(CameraImage image) async {
    final recognizer = _liveScanRecognizer;
    final controller = _controller;
    if (recognizer == null || controller == null) return false;
    if (image.planes.isEmpty) return false;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    final rotation = InputImageRotationValue.fromRawValue(
      controller.description.sensorOrientation,
    );
    if (format == null || rotation == null) return false;

    final bytes = image.planes.fold<Uint8List>(Uint8List(0), (
      previousValue,
      plane,
    ) {
      final merged = Uint8List(previousValue.length + plane.bytes.length);
      merged.setRange(0, previousValue.length, previousValue);
      merged.setRange(previousValue.length, merged.length, plane.bytes);
      return merged;
    });

    if (bytes.isEmpty) return false;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    final input = InputImage.fromBytes(bytes: bytes, metadata: metadata);
    final recognized = await recognizer.processImage(input);
    final raw = recognized.text.toLowerCase();
    if (raw.trim().length < 12) return false;

    var evidence = 0;
    if (RegExp(
      r'\b(hp|stage|basic|trainer|energy|weakness|resistance|retreat)\b',
    ).hasMatch(raw)) {
      evidence += 1;
    }
    if (RegExp(r'\b(mega|ex|gx|vmax|vstar)\b').hasMatch(raw)) {
      evidence += 1;
    }
    if (RegExp(r'\d{1,4}\s*/\s*\d{2,4}').hasMatch(raw)) {
      evidence += 1;
    }
    if (recognized.blocks.length >= 3) {
      evidence += 1;
    }
    return evidence >= 2;
  }

  Future<void> _autoCapturePhoto() async {
    await _takePhoto(fromLiveScan: true);
  }

  Future<void> _takePhoto({bool fromLiveScan = false}) async {
    final controller = _controller;
    if (controller == null) return;

    try {
      if (!controller.value.isInitialized) return;
      if (controller.value.isTakingPicture) return;
      if (_liveScanStreaming || controller.value.isStreamingImages) {
        await _stopLiveScan();
      }

      final file = await controller.takePicture();
      if (!mounted) return;
      setState(() {
        _captured = file;
        if (fromLiveScan) {
          _liveScanStatus = 'Card detected';
        }
      });
    } catch (e) {
      if (fromLiveScan) {
        _autoCaptureTriggered = false;
        unawaited(_maybeStartLiveScan());
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    }
  }

  void _retake() {
    setState(() {
      _captured = null;
      _autoCaptureTriggered = false;
      _stableLiveDetections = 0;
      _liveScanStatus = 'Looking for card…';
    });
    if (_liveScanEnabled) {
      unawaited(_maybeStartLiveScan());
    }
  }

  void _usePhoto() {
    final file = _captured;
    if (file == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecognizingScreen(
          photoPath: file.path,
          expectedSetId: widget.expectedSetId,
          expectedSlot: widget.expectedSlot,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.expectedSetId != null && widget.expectedSlot != null
              ? 'Scan #${widget.expectedSlot} (${widget.expectedSetId})'
              : 'Scan',
        ),
      ),
      body: controller == null
          ? const Center(child: Text('No camera found on this device/emulator'))
          : FutureBuilder<void>(
              future: _initFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Text('Camera error: ${snapshot.error}'),
                    );
                  }
                  return const Center(child: CircularProgressIndicator());
                }

                if (_captured != null) {
                  return _PreviewScreen(
                    path: _captured!.path,
                    onRetake: _retake,
                    onUse: _usePhoto,
                  );
                }

                return Stack(
                  children: [
                    Positioned.fill(child: CameraPreview(controller)),
                    if (_liveScanEnabled)
                      Positioned(
                        top: 18,
                        left: 16,
                        right: 16,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.58),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.12),
                              ),
                            ),
                            child: Text(
                              _liveScanStatus,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Center(
                      child: Container(
                        width: MediaQuery.of(context).size.width * 0.78,
                        height: MediaQuery.of(context).size.height * 0.55,
                        decoration: BoxDecoration(
                          border: Border.all(width: 3),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 28,
                      child: Center(
                        child: GestureDetector(
                          onTap: () => _takePhoto(),
                          child: Container(
                            width: 74,
                            height: 74,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(width: 5),
                              color: Colors.white.withOpacity(0.1),
                            ),
                            child: const Center(
                              child: Icon(Icons.camera_alt, size: 30),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  final String path;
  final VoidCallback onRetake;
  final VoidCallback onUse;

  const _PreviewScreen({
    required this.path,
    required this.onRetake,
    required this.onUse,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withOpacity(0.12)),
                  ),
                  child: const Text(
                    'Card captured',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Make sure the card name and number are visible.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.74),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: Image.file(File(path), fit: BoxFit.contain),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onRetake,
                    child: const Text('Retake'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onUse,
                    child: const Text('Identify card'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/* -------------------------- MANUAL SEARCH FLOW --------------------------- */

class ManualSearchScreen extends StatefulWidget {
  const ManualSearchScreen({super.key});

  @override
  State<ManualSearchScreen> createState() => _ManualSearchScreenState();
}

class _ManualSearchScreenState extends State<ManualSearchScreen> {
  final _nameController = TextEditingController();
  final _setController = TextEditingController();
  final _numberController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _setController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  void _search() {
    final name = _nameController.text.trim();
    final set = _setController.text.trim();
    final number = _numberController.text.trim();

    // ignore: avoid_print
    print(
      'TRACE manual_search.submit name="$name" set="${set.isEmpty ? '' : set}" number="${number.isEmpty ? '' : number}"',
    );

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a Pokémon or card name to search.'),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) {
          // ignore: avoid_print
          print(
            'TRACE manual_search.navigate_to_results name="$name" set="${set.isEmpty ? '' : set}" number="${number.isEmpty ? '' : number}"',
          );
          return SearchResultsScreen(
            name: name,
            set: set.isEmpty ? null : set,
            number: number.isEmpty ? null : number,
            browseOnly: true,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manual Search')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Look up any Pokémon card',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'Search by name, then optionally narrow by set or card number.',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          TextField(
            controller: _nameController,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: 'Pokémon / card name',
              hintText: 'e.g. Charizard, Giratina VSTAR, Pikachu',
              prefixIcon: Icon(Icons.search),
            ),
            onSubmitted: (_) => _search(),
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _setController,
            decoration: const InputDecoration(
              labelText: 'Set (optional)',
              hintText: 'e.g. Base, 151, Lost Origin',
              prefixIcon: Icon(Icons.collections_bookmark_outlined),
            ),
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _numberController,
            decoration: const InputDecoration(
              labelText: 'Card number (optional)',
              hintText: 'e.g. 4, 183, 131',
              prefixIcon: Icon(Icons.pin_outlined),
            ),
          ),

          const SizedBox(height: 18),

          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.search),
              label: const Text('Search cards'),
            ),
          ),

          const SizedBox(height: 14),

          Text(
            'Note: Manual Search is for browsing cards. Add to collection should happen through scanning.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(0.68),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFallbackPanel extends StatelessWidget {
  final String query;
  final VoidCallback onRetry;

  const _EmptyFallbackPanel({required this.query, required this.onRetry});

  Uri _ebaySoldUrl(String q) {
    final enc = Uri.encodeComponent(q);
    return Uri.parse(
      'https://www.ebay.com/sch/i.html?_nkw=$enc&LH_Sold=1&LH_Complete=1',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44),
            const SizedBox(height: 10),
            const Text(
              'No results yet (and live results may be slow).',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await launchUrl(
                  _ebaySoldUrl(query),
                  mode: LaunchMode.externalApplication,
                );
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open eBay')),
                  );
                }
              },
              icon: const Icon(Icons.shopping_bag_outlined),
              label: const Text('View sold listings on eBay'),
            ),
          ],
        ),
      ),
    );
  }
}

/* ---------------------------- SEARCH RESULTS ---------------------------- */

class SearchResultsScreen extends StatefulWidget {
  final String name;
  final String? set;
  final String? number;
  final List<PokemonCardResult>? prefetched;
  final bool browseOnly;
  final bool scannerFallback;
  final String? expectedSetId;
  final int? expectedSlot;

  const SearchResultsScreen({
    super.key,
    required this.name,
    this.set,
    this.number,
    this.prefetched,
    this.browseOnly = false,
    this.scannerFallback = false,
    this.expectedSetId,
    this.expectedSlot,
  });

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  bool _loading = true;
  bool _updating = false;
  String? _error;
  List<PokemonCardResult> _results = const [];
  bool _loggedFirstResultsRender = false;
  bool _loggedEmptyStateRender = false;

  @override
  void initState() {
    super.initState();
    // ignore: avoid_print
    print(
      'TRACE results_screen.init name="${widget.name}" set="${widget.set ?? ''}" number="${widget.number ?? ''}" prefetched=${widget.prefetched?.length ?? 0}',
    );

    final pre = widget.prefetched;
    if (pre != null && pre.isNotEmpty) {
      _results = pre;
      _loading = false;
      _updating = false;
      _error = null;

      if (pre.length == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final c = pre.first;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PokemonCardDetailsScreen(
                card: c,
                expectedSetId: widget.expectedSetId,
                expectedSlot: widget.expectedSlot,
                compactAddMode: widget.scannerFallback,
                readOnly: widget.scannerFallback ? false : widget.browseOnly,
              ),
            ),
          );
        });
      }
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    // ignore: avoid_print
    print(
      'TRACE results_screen.load.start name="${widget.name}" set="${widget.set ?? ''}" number="${widget.number ?? ''}"',
    );
    setState(() {
      _loading = true;
      _updating = false;
      _error = null;
      _loggedFirstResultsRender = false;
      _loggedEmptyStateRender = false;
    });

    final api = PokemonTcgApi();

    try {
      final cached = await api.getCachedSearch(
        name: widget.name,
        set: widget.set,
        number: widget.number,
      );
      // ignore: avoid_print
      print('TRACE results_screen.load.cached_return count=${cached.length}');
      if (!mounted) return;

      if (cached.isNotEmpty) {
        setState(() {
          _results = cached;
          _loading = false;
          _updating = true;
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('TRACE results_screen.load.cached_error error=$e');
    }

    try {
      final live = await api.refreshSearch(
        name: widget.name,
        set: widget.set,
        number: widget.number,
      );
      // ignore: avoid_print
      print('TRACE results_screen.load.live_return count=${live.length}');
      if (!mounted) return;

      setState(() {
        _results = live;
        _loading = false;
        _updating = false;
        _error = live.isEmpty
            ? (widget.browseOnly
                  ? 'Try adding the card number for a more exact match.'
                  : 'No results found.')
            : null;
      });
      // ignore: avoid_print
      print(
        'TRACE results_screen.load.state_updated loading=$_loading updating=$_updating error="${_error ?? ''}" results=${_results.length}',
      );
    } catch (e) {
      // ignore: avoid_print
      print('TRACE results_screen.load.live_error error=$e');
      if (!mounted) return;

      setState(() {
        _loading = false;
        _updating = false;
        if (_results.isEmpty) {
          _error = 'Live results are unavailable right now. Please try again.';
        }
      });
      // ignore: avoid_print
      print(
        'TRACE results_screen.load.error_state_updated loading=$_loading updating=$_updating error="${_error ?? ''}" results=${_results.length}',
      );
    }
  }

  Widget _imageFallback() {
    return Container(
      color: Colors.white.withOpacity(0.05),
      child: const Center(
        child: Icon(Icons.image_not_supported_outlined, color: Colors.white54),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;

    if (!_loading && results.isNotEmpty && !_loggedFirstResultsRender) {
      _loggedFirstResultsRender = true;
      // ignore: avoid_print
      print(
        'TRACE results_screen.render.results count=${results.length} first="${results.first.name}"',
      );
    }

    if (!_loading &&
        _error != null &&
        results.isEmpty &&
        !_loggedEmptyStateRender) {
      _loggedEmptyStateRender = true;
      // ignore: avoid_print
      print('TRACE results_screen.render.empty error="$_error"');
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.browseOnly ? 'Browse Cards' : 'Results'),
        actions: [
          IconButton(
            tooltip: 'Retry',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_updating) const LinearProgressIndicator(minHeight: 2),
          if (_loading && results.isEmpty)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Searching...', textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            )
          else if (_error != null && results.isEmpty)
            Expanded(
              child: _error == 'No results found.'
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ),
                    )
                  : _EmptyFallbackPanel(
                      query: '${widget.name} ${widget.number ?? ''}'.trim(),
                      onRetry: _load,
                    ),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: results.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final c = results[i];
                  final img = c.imageSmall.isNotEmpty
                      ? c.imageSmall
                      : c.imageLarge;
                  final hasImg =
                      img.startsWith('http://') || img.startsWith('https://');

                  return InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PokemonCardDetailsScreen(
                            card: c,
                            expectedSetId: widget.expectedSetId,
                            expectedSlot: widget.expectedSlot,
                            compactAddMode: widget.scannerFallback,
                            readOnly: widget.scannerFallback
                                ? false
                                : widget.browseOnly,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withOpacity(0.06),
                            Colors.white.withOpacity(0.025),
                          ],
                        ),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.18),
                            blurRadius: 16,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: SizedBox(
                              width: 82,
                              height: 114,
                              child: hasImg
                                  ? Image.network(
                                      img,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Container(
                                        color: Colors.white.withOpacity(0.05),
                                        child: const Center(
                                          child: Icon(
                                            Icons.image_not_supported_outlined,
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      color: Colors.white.withOpacity(0.05),
                                      child: const Center(
                                        child: Icon(
                                          Icons.image_not_supported_outlined,
                                          color: Colors.white54,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w900,
                                      height: 1.15,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    c.setName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.76),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '#${c.number}',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.62),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.06),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      widget.browseOnly
                                          ? 'View card details'
                                          : 'Tap to inspect',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Icon(
                              Icons.chevron_right,
                              color: Colors.white.withOpacity(0.72),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/* ---------------------------- COLLECTION SCREEN --------------------------- */

enum _CollectionSort { newest, valueHighToLow, nameAZ }

class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key});

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  List<SetSummary> _allSets = const <SetSummary>[];
  List<SetSummary> _visibleSets = const <SetSummary>[];
  List<_CollectionSearchHit> _searchHits = const <_CollectionSearchHit>[];
  List<_OwnedSearchCandidate> _searchSource = const <_OwnedSearchCandidate>[];

  @override
  void initState() {
    super.initState();
    _allSets = collectionStore.getSetSummariesView();
    _visibleSets = _allSets;
    _searchSource = _buildOwnedSearchSource(_allSets);
    collectionStore.collectionViewVersion.addListener(_onCollectionChanged);
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    collectionStore.collectionViewVersion.removeListener(_onCollectionChanged);
    super.dispose();
  }

  void _onCollectionChanged() {
    final summaries = collectionStore.getSetSummariesView();
    final source = _buildOwnedSearchSource(summaries);
    final nextHits = _query.isEmpty
        ? const <_CollectionSearchHit>[]
        : _buildCollectionSearchHits(source, _query);
    if (!mounted) return;
    setState(() {
      _allSets = summaries;
      _visibleSets = _filterSetSummaries(summaries, _query);
      _searchSource = source;
      _searchHits = nextHits;
    });
  }

  void _onSearchChanged() {
    final nextQuery = _searchCtrl.text.trim().toLowerCase();
    if (nextQuery == _query) return;

    _searchDebounce?.cancel();

    if (nextQuery.isEmpty) {
      setState(() {
        _query = '';
        _visibleSets = _allSets;
        _searchHits = const <_CollectionSearchHit>[];
      });
      return;
    }

    setState(() => _query = nextQuery);

    _searchDebounce = Timer(const Duration(milliseconds: 60), () {
      final hits = _buildCollectionSearchHits(_searchSource, nextQuery);
      if (!mounted || nextQuery != _query) return;
      setState(() {
        _visibleSets = _filterSetSummaries(_allSets, nextQuery);
        _searchHits = hits;
      });
    });
  }

  List<_OwnedSearchCandidate> _buildOwnedSearchSource(
    List<SetSummary> summaries,
  ) {
    final source = <_OwnedSearchCandidate>[];

    for (final summary in summaries) {
      final ownedMap = collectionStore.ownedSlotMapViewForSet(summary.setKey);

      for (final entry in ownedMap.entries) {
        final slot = entry.key;
        final owned = entry.value;
        final name = owned.name.trim();
        if (name.isEmpty) continue;

        final hit = _CollectionSearchHit(
          setKey: summary.setKey,
          setName: summary.setName,
          printedTotal: summary.printedTotal,
          slot: slot,
          ownedCard: owned,
        );

        source.add(
          _OwnedSearchCandidate(
            haystack: '${owned.name} ${summary.setName} ${owned.number} $slot'
                .toLowerCase(),
            hit: hit,
          ),
        );
      }
    }

    return source;
  }

  List<SetSummary> _filterSetSummaries(List<SetSummary> sets, String query) {
    if (query.isEmpty) return sets;
    return sets.where((s) {
      final hay = '${s.setName} ${s.setId ?? ''}'.toLowerCase();
      return hay.contains(query);
    }).toList();
  }

  List<_CollectionSearchHit> _buildCollectionSearchHits(
    List<_OwnedSearchCandidate> source,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const <_CollectionSearchHit>[];

    final hits = <_CollectionSearchHit>[];

    for (final candidate in source) {
      if (!candidate.haystack.contains(q)) continue;
      hits.add(candidate.hit);
    }

    hits.sort((a, b) {
      final aName = a.displayName.toLowerCase();
      final bName = b.displayName.toLowerCase();
      final aPrefix = aName.startsWith(q) ? 0 : 1;
      final bPrefix = bName.startsWith(q) ? 0 : 1;
      if (aPrefix != bPrefix) return aPrefix.compareTo(bPrefix);
      final byName = aName.compareTo(bName);
      if (byName != 0) return byName;
      final bySet = a.setName.toLowerCase().compareTo(b.setName.toLowerCase());
      if (bySet != 0) return bySet;
      return a.slot.compareTo(b.slot);
    });

    return hits;
  }

  void _openCollectionSearchHit(_CollectionSearchHit hit) {
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: 'set_pokedex'),
        builder: (_) => SetPokedexScreen(
          setKey: hit.setKey,
          setName: hit.setName,
          printedTotal: hit.printedTotal,
          initialSlot: hit.slot,
        ),
      ),
    );
  }

  Widget _buildCardSearchResults(List<_CollectionSearchHit> hits) {
    if (hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 42,
                color: Colors.white.withOpacity(0.5),
              ),
              const SizedBox(height: 12),
              const Text(
                'No cards match this search.',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                'Try a card name like Charizard or Pikachu.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  height: 1.4,
                  color: Colors.white.withOpacity(0.72),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 860
            ? 5
            : width >= 640
            ? 4
            : 3;
        final cacheExtent = (constraints.maxHeight * 0.5).clamp(240.0, 640.0);

        return GridView.builder(
          cacheExtent: cacheExtent,
          addAutomaticKeepAlives: false,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 14,
            crossAxisSpacing: 12,
            childAspectRatio: 0.57,
          ),
          itemCount: hits.length,
          itemBuilder: (context, index) {
            final hit = hits[index];
            return _CollectionSearchResultTile(
              hit: hit,
              onTap: () => _openCollectionSearchHit(hit),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final allSets = _allSets;
    final hasCollectionContent =
        allSets.isNotEmpty || collectionStore.count > 0;
    final sets = _visibleSets;
    final totalCards = collectionStore.count;
    final completedSets = allSets
        .where(
          (s) =>
              s.printedTotal != null && s.printedTotal! > 0 && s.progress >= 1,
        )
        .length;
    final searchHits = _searchHits;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Collection'),
        actions: [
          IconButton(
            tooltip: 'Clear (testing)',
            onPressed: !hasCollectionContent
                ? null
                : () => collectionStore.clear(),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: hasCollectionContent
          ? Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: _CollectionLandingHeader(
                    totalSets: allSets.length,
                    totalCards: totalCards,
                    completedSets: completedSets,
                    searchField: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Search cards or sets...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () => _searchCtrl.clear(),
                              ),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.06),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _query.isEmpty
                      ? ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                          itemCount: sets.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 14),
                          itemBuilder: (context, i) {
                            final s = sets[i];
                            return _CollectionSetTile(
                              summary: s,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    settings: const RouteSettings(
                                      name: 'set_pokedex',
                                    ),
                                    builder: (_) => SetPokedexScreen(
                                      setKey: s.setKey,
                                      setName: s.setName,
                                      printedTotal: s.printedTotal,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        )
                      : _buildCardSearchResults(searchHits),
                ),
              ],
            )
          : const _PreCollectionState(),
    );
  }
}

class _CollectionLandingHeader extends StatelessWidget {
  final int totalSets;
  final int totalCards;
  final int completedSets;
  final Widget searchField;

  const _CollectionLandingHeader({
    required this.totalSets,
    required this.totalCards,
    required this.completedSets,
    required this.searchField,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF13203B), Color(0xFF0B1020)],
        ),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'COLLECTOR VAULT',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
              color: Colors.white.withOpacity(0.74),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Your sets, progress, and missing slots in one place.',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Open a set to fill your Pokédex and turn grayscale gaps into collected cards.',
            style: TextStyle(
              height: 1.45,
              fontWeight: FontWeight.w600,
              color: Colors.white.withOpacity(0.76),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _CollectionStatPill(
                  label: 'Sets',
                  value: '$totalSets',
                  icon: Icons.auto_awesome_mosaic_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CollectionStatPill(
                  label: 'Cards',
                  value: '$totalCards',
                  icon: Icons.style_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CollectionStatPill(
                  label: 'Complete',
                  value: '$completedSets',
                  icon: Icons.workspace_premium_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          searchField,
        ],
      ),
    );
  }
}

class _CollectionStatPill extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _CollectionStatPill({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.white.withOpacity(0.84)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CollectionSetTile extends StatelessWidget {
  final SetSummary summary;
  final VoidCallback onTap;

  const _CollectionSetTile({required this.summary, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final total = summary.printedTotal ?? 0;
    final percent = (summary.progress * 100).round();
    final missingCount = total > 0 ? (total - summary.ownedUniqueSlots) : 0;
    final progressText = total > 0
        ? '${summary.ownedUniqueSlots} / $total'
        : '${summary.ownedInstances} cards';
    final subtitle = total > 0
        ? '$percent% complete - $missingCount locked'
        : 'cards captured';
    final footer = total > 0
        ? 'Tap to fill your Pokédex'
        : 'Tap to view your cards';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF162847), Color(0xFF0D1426)],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SET PROGRESS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                              color: Colors.white.withOpacity(0.66),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            summary.setName,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            progressText,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withOpacity(0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            total > 0
                                ? '$percent%'
                                : '${summary.ownedInstances}',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            total > 0 ? 'complete' : 'cards',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Colors.white.withOpacity(0.68),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value:
                        (summary.printedTotal == null ||
                            summary.printedTotal == 0)
                        ? null
                        : summary.progress,
                    minHeight: 14,
                    backgroundColor: Colors.white.withOpacity(0.08),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Text(
                        footer,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withOpacity(0.84),
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.chevron_right_rounded, size: 28),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollectionSearchHit {
  final String setKey;
  final String setName;
  final int? printedTotal;
  final int slot;
  final PokemonCardResult ownedCard;

  const _CollectionSearchHit({
    required this.setKey,
    required this.setName,
    required this.printedTotal,
    required this.slot,
    required this.ownedCard,
  });

  String get displayName => ownedCard.name;
}

class _OwnedSearchCandidate {
  final String haystack;
  final _CollectionSearchHit hit;

  const _OwnedSearchCandidate({required this.haystack, required this.hit});
}

class _CollectionSearchResultTile extends StatelessWidget {
  final _CollectionSearchHit hit;
  final VoidCallback onTap;

  const _CollectionSearchResultTile({required this.hit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _OwnedSlotTile(
              slot: hit.slot,
              card: hit.ownedCard,
              onTap: onTap,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hit.setName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(0.74),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreCollectionState extends StatelessWidget {
  const _PreCollectionState();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const _PreCollectionHero(),
                const SizedBox(height: 28),
                Text(
                  'Unlock Your Collection',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Scan your first real card to open your binder, reveal set progress, and start filling missing slots.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    height: 1.45,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withOpacity(0.78),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: const [
                    _CollectionPromiseChip(
                      icon: Icons.collections_bookmark_outlined,
                      label: 'Track real sets',
                    ),
                    _CollectionPromiseChip(
                      icon: Icons.auto_awesome_outlined,
                      label: 'Reveal missing cards',
                    ),
                    _CollectionPromiseChip(
                      icon: Icons.workspace_premium_outlined,
                      label: 'Build binder progress',
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ScanScreen(cameras: gCameras),
                        ),
                      );
                    },
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Scan your first card'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreCollectionHero extends StatelessWidget {
  const _PreCollectionHero();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.08,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF13203B), Color(0xFF0A0F1D)],
          ),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.25),
                    radius: 0.95,
                    colors: [
                      Colors.white.withOpacity(0.11),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: SizedBox(
                width: 250,
                height: 250,
                child: Stack(
                  alignment: Alignment.center,
                  children: const [
                    _PreCollectionCard(angle: -0.22, dx: -64, dy: 18),
                    _PreCollectionCard(angle: 0.18, dx: 64, dy: 18),
                    _PreCollectionCard(angle: 0, dx: 0, dy: -8, locked: true),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreCollectionCard extends StatelessWidget {
  final double angle;
  final double dx;
  final double dy;
  final bool locked;

  const _PreCollectionCard({
    required this.angle,
    required this.dx,
    required this.dy,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget card = Container(
      width: 126,
      height: 176,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.18),
            Colors.white.withOpacity(0.06),
          ],
        ),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.22),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: double.infinity,
                    height: 68,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: 72,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (locked)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.48),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white.withOpacity(0.14)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 16),
                    SizedBox(width: 6),
                    Text(
                      'LOCKED',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    card = ColorFiltered(
      colorFilter: const ColorFilter.matrix(kGreyMatrix),
      child: card,
    );

    return Transform.translate(
      offset: Offset(dx, dy),
      child: Transform.rotate(angle: angle, child: card),
    );
  }
}

class _CollectionPromiseChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _CollectionPromiseChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// ------------------------- SET POKEDEX SCREEN -------------------------

class SetPokedexScreen extends StatefulWidget {
  final String setKey;
  final String setName;
  final int? printedTotal;
  final int? initialSlot;

  const SetPokedexScreen({
    super.key,
    required this.setKey,
    required this.setName,
    required this.printedTotal,
    this.initialSlot,
  });

  @override
  State<SetPokedexScreen> createState() => _SetPokedexScreenState();
}

class _SetPokedexScreenState extends State<SetPokedexScreen> {
  final _searchCtrl = TextEditingController();
  final ScrollController _gridScrollCtrl = ScrollController();
  String _query = '';

  CollectedEvent? _celebrate;
  bool _showCelebrate = false;
  int? _justUnlockedSlot;
  int _slotHighlightToken = 0;
  bool _didInitialSlotReveal = false;

  void _onCollectedEvent() {
    final e = collectionStore.lastCollected.value;
    if (e == null) return;
    if (e.setKey != widget.setKey) return;

    setState(() {
      _celebrate = e;
      _showCelebrate = true;
    });

    _flashSlotHighlight(e.slot, duration: const Duration(milliseconds: 1800));

    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _showCelebrate = false);
    });
  }

  @override
  void initState() {
    super.initState();

    collectionStore.collectionViewVersion.addListener(_onChanged);
    collectionStore.setIndexVersion.addListener(_onChanged);
    collectionStore.lastCollected.addListener(_onCollectedEvent);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      collectionStore.ensureSetIndexLoaded(
        setKey: widget.setKey,
        setId: widget.setKey,
      );
    });

    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _gridScrollCtrl.dispose();
    collectionStore.collectionViewVersion.removeListener(_onChanged);
    collectionStore.setIndexVersion.removeListener(_onChanged);
    collectionStore.lastCollected.removeListener(_onCollectedEvent);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _flashSlotHighlight(int slot, {required Duration duration}) {
    final token = ++_slotHighlightToken;
    setState(() => _justUnlockedSlot = slot);

    Future.delayed(duration, () {
      if (!mounted) return;
      if (_slotHighlightToken != token) return;
      setState(() => _justUnlockedSlot = null);
    });
  }

  void _maybeRevealInitialSlot({
    required List<int> slots,
    required int crossAxisCount,
    required double maxWidth,
  }) {
    final targetSlot = widget.initialSlot;
    if (targetSlot == null || _didInitialSlotReveal) return;

    final targetIndex = slots.indexOf(targetSlot);
    if (targetIndex < 0) return;
    _didInitialSlotReveal = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final usableWidth = maxWidth - 32;
      final childWidth =
          (usableWidth - ((crossAxisCount - 1) * 12)) / crossAxisCount;
      final childHeight = childWidth / 0.7;
      final row = targetIndex ~/ crossAxisCount;
      final targetOffset = row * (childHeight + 12);

      if (_gridScrollCtrl.hasClients) {
        final maxOffset = _gridScrollCtrl.position.maxScrollExtent;
        _gridScrollCtrl.animateTo(
          targetOffset.clamp(0.0, maxOffset),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      }

      _flashSlotHighlight(
        targetSlot,
        duration: const Duration(milliseconds: 2200),
      );
    });
  }

  void _maybeSeedInitialSlotFallback(bool showGrid) {
    final targetSlot = widget.initialSlot;
    if (showGrid ||
        targetSlot == null ||
        _didInitialSlotReveal ||
        _query.isNotEmpty) {
      return;
    }

    _didInitialSlotReveal = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchCtrl.text = '$targetSlot';
      _flashSlotHighlight(
        targetSlot,
        duration: const Duration(milliseconds: 2200),
      );
    });
  }

  int? _parseInt(String s) => int.tryParse(s);

  List<int> _filteredSlots(
    int total,
    Map<int, PokemonCardResult> ownedMap,
    Map<int, PreviewCard> previewMap,
  ) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return List<int>.generate(total, (i) => i + 1);

    final qNum = _parseInt(q);
    if (qNum != null) {
      return (qNum >= 1 && qNum <= total) ? <int>[qNum] : const <int>[];
    }

    final slots = <int>[];
    for (var slot = 1; slot <= total; slot++) {
      final owned = ownedMap[slot];
      final preview = previewMap[slot];
      final hay = owned != null
          ? '${owned.name} ${owned.number}'.toLowerCase()
          : '${preview?.name ?? ''} $slot'.toLowerCase();
      if (hay.contains(q)) {
        slots.add(slot);
      }
    }
    return slots;
  }

  int _gridCrossAxisCount(double width) {
    if (width >= 700) return 5;
    return 4;
  }

  @override
  Widget build(BuildContext context) {
    final ownedMap = collectionStore.ownedSlotMapViewForSet(widget.setKey);
    final previewMap = collectionStore.previewSlotMapViewForSet(widget.setKey);

    final maxOwned = ownedMap.isEmpty
        ? 0
        : ownedMap.keys.reduce((a, b) => a > b ? a : b);

    final total = (() {
      final printed = widget.printedTotal ?? 0;
      final computed = printed > maxOwned ? printed : maxOwned;
      if (computed > 500) return 500;
      return computed;
    })();

    final progressTotal = widget.printedTotal ?? total;
    final ownedCount = collectionStore.registeredCountForSet(widget.setKey);
    final showGrid = total >= 10 && total <= 500;
    _maybeSeedInitialSlotFallback(showGrid);
    final progressValue = progressTotal == 0
        ? 0.0
        : (ownedCount / progressTotal).clamp(0.0, 1.0);
    final progressPercent = (progressValue * 100).round();

    return Scaffold(
      appBar: AppBar(title: Text(widget.setName)),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF14233F), Color(0xFF0B1222)],
                    ),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.18),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'SET VAULT',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2,
                                    color: Colors.white.withOpacity(0.68),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  widget.setName,
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w900,
                                    height: 1.05,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  showGrid
                                      ? '$ownedCount / $progressTotal collected - ${progressTotal - ownedCount} locked'
                                      : '${ownedMap.length} cards in this set',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white.withOpacity(0.8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (showGrid)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.08),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    '$progressPercent%',
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'complete',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white.withOpacity(0.68),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      if (showGrid) ...[
                        const SizedBox(height: 14),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: progressValue,
                            minHeight: 12,
                            backgroundColor: Colors.white.withOpacity(0.08),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      TextField(
                        controller: _searchCtrl,
                        decoration: InputDecoration(
                          hintText: showGrid
                              ? 'Filter by card name or slot number...'
                              : 'Search your cards...',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () => _searchCtrl.clear(),
                                ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: BorderSide(
                              color: Colors.white.withOpacity(0.08),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: BorderSide(
                              color: Colors.white.withOpacity(0.08),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: showGrid
                    ? _buildPokedexGrid(context, total, ownedMap, previewMap)
                    : _buildOwnedList(context, ownedMap),
              ),
            ],
          ),
          if (_showCelebrate && _celebrate != null)
            Positioned.fill(child: _CollectedOverlay(event: _celebrate!)),
        ],
      ),
    );
  }

  Widget _buildPokedexGrid(
    BuildContext context,
    int total,
    Map<int, PokemonCardResult> ownedMap,
    Map<int, PreviewCard> previewMap,
  ) {
    final slots = _filteredSlots(total, ownedMap, previewMap);

    if (slots.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 42,
                color: Colors.white.withOpacity(0.5),
              ),
              const SizedBox(height: 12),
              const Text(
                'No cards match this filter.',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                'Try a card name like Charizard or a slot number like 39.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  height: 1.4,
                  color: Colors.white.withOpacity(0.72),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _gridCrossAxisCount(constraints.maxWidth);
        final cacheExtent = (constraints.maxHeight * 0.5).clamp(240.0, 640.0);

        _maybeRevealInitialSlot(
          slots: slots,
          crossAxisCount: crossAxisCount,
          maxWidth: constraints.maxWidth,
        );

        return GridView.builder(
          controller: _gridScrollCtrl,
          cacheExtent: cacheExtent,
          addAutomaticKeepAlives: false,
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.7,
          ),
          itemCount: slots.length,
          itemBuilder: (context, idx) {
            final slot = slots[idx];
            final owned = ownedMap[slot];
            final preview = previewMap[slot];

            if (owned != null) {
              return _OwnedSlotTile(
                slot: slot,
                card: owned,
                isJustUnlocked: _justUnlockedSlot == slot,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => OwnedCardShowcaseScreen(card: owned),
                    ),
                  );
                },
              );
            }

            return _MissingSlotTile(
              slot: slot,
              previewImageUrl: preview?.imageSmall,
              previewName: preview?.name,
              showPreviewLabel: _query.trim().isNotEmpty,
              isFocused: _justUnlockedSlot == slot,
              onTap: () => _showSlotSheet(slot: slot, preview: preview),
            );
          },
        );
      },
    );
  }

  void _showSlotSheet({required int slot, required PreviewCard? preview}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LockedCardShowcaseScreen(
          slot: slot,
          preview: preview,
          setKey: widget.setKey,
          setName: widget.setName,
        ),
      ),
    );
  }

  Widget _buildOwnedList(
    BuildContext context,
    Map<int, PokemonCardResult> ownedMap,
  ) {
    final cards = ownedMap.values.toList();
    final q = _query;

    if (q.isNotEmpty) {
      cards.removeWhere(
        (c) => !('${c.name} ${c.number}'.toLowerCase().contains(q)),
      );
    }

    if (cards.isEmpty) {
      return const Center(child: Text('No cards match your search.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: cards.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final c = cards[i];
        return Card(
          child: ListTile(
            leading: c.imageSmall.isEmpty
                ? const Icon(Icons.image_not_supported)
                : Image.network(c.imageSmall, width: 56, fit: BoxFit.cover),
            title: Text(c.name),
            subtitle: Text('#${c.number}'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => OwnedCardShowcaseScreen(card: c),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class LockedCardShowcaseScreen extends StatelessWidget {
  final int slot;
  final PreviewCard? preview;
  final String setKey;
  final String setName;

  const LockedCardShowcaseScreen({
    super.key,
    required this.slot,
    required this.preview,
    required this.setKey,
    required this.setName,
  });

  @override
  Widget build(BuildContext context) {
    final name = (preview?.name ?? '').trim();
    final title = name.isNotEmpty ? name : 'Register #$slot';
    final subtitle = name.isNotEmpty ? '$name - Slot #$slot' : 'Slot #$slot';

    final img = (preview?.imageSmall ?? '').trim();
    final label = '#$slot';
    final ebayQuery = buildEbayQuery(
      name: name.isNotEmpty ? name : 'Pokemon card',
      setName: setName,
      number: '$slot',
      printedTotal: null,
      mode: EbayMode.raw,
    );
    final ebaySearchUrl = Uri.parse(
      'https://www.ebay.com/sch/i.html?_nkw=${Uri.encodeComponent(ebayQuery)}',
    );
    final ebaySoldUrl = Uri.parse(
      'https://www.ebay.com/sch/i.html?_nkw=${Uri.encodeComponent(ebayQuery)}&LH_Sold=1&LH_Complete=1',
    );

    return Scaffold(
      appBar: AppBar(title: Text('Register #$slot')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 28,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Column(
                      children: [
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withOpacity(0.75),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Stage / Card
                    AspectRatio(
                      aspectRatio: 0.95,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(painter: _SpotlightPainter()),
                          ),
                          Center(
                            child: _LockedStageCard(
                              slot: slot,
                              imageUrl: img,
                              label: label,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ScanScreen(
                                cameras: gCameras,
                                expectedSetId: setKey,
                                expectedSlot: slot,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Scan this card'),
                      ),
                    ),

                    const SizedBox(height: 14),

                    _LockedPanel(
                      title: 'Details',
                      subtitle: 'Locked until you scan this card.',
                      icon: Icons.lock,
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'eBay',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Browse active or sold listings while this card is still missing from your Pokédex.',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.76),
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 14),
                          const SizedBox(height: 12),
                          EbayListingPreviewSection(
                            query: ebayQuery,
                            accentColor: const Color(0xFF7DD3FC),
                            title: 'eBay Preview',
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class PokedexRegisterAnimationScreen extends StatefulWidget {
  final PokemonCardResult card;
  final String setKey;
  final int slot;

  const PokedexRegisterAnimationScreen({
    super.key,
    required this.card,
    required this.setKey,
    required this.slot,
  });

  @override
  State<PokedexRegisterAnimationScreen> createState() =>
      _PokedexRegisterAnimationScreenState();
}

class _PokedexRegisterAnimationScreenState
    extends State<PokedexRegisterAnimationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  late final Animation<double> _fadeIn;
  late final Animation<double> _spin;
  late final Animation<double> _drop;
  late final Animation<double> _impact;

  bool _didPrecache = false;
  bool _imageReady = false;

  String get _cardUrl => widget.card.imageSmall.isNotEmpty
      ? widget.card.imageSmall
      : widget.card.imageLarge;

  bool get _showColor => _c.value > 0.62;

  @override
  void initState() {
    super.initState();

    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );

    _fadeIn = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.0, 0.12, curve: Curves.easeOut),
    );

    _spin = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.08, 0.78, curve: Curves.easeOutCubic),
    );

    _drop = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.0, 0.62, curve: Curves.easeOutCubic),
    );

    _impact = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.62, 1.0, curve: Curves.elasticOut),
    );

    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        _finishToShowcase();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didPrecache) return;
    _didPrecache = true;

    final url = _cardUrl;
    if (url.isEmpty) {
      _imageReady = true;
      _c.forward();
      return;
    }

    // âœ… Safe: context is valid here
    precacheImage(NetworkImage(url), context)
        .then((_) {
          if (!mounted) return;
          setState(() => _imageReady = true);
          _c.forward();
        })
        .catchError((_) {
          if (!mounted) return;
          setState(() => _imageReady = true);
          _c.forward();
        });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _finishToShowcase() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PostScanOwnedShowcaseScreen(
          card: widget.card,
          returnTarget: _PostScanReturnTarget.setPokedex(
            setKey: widget.setKey,
            slot: widget.slot,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _cardUrl;

    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeIn,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(painter: _StageLightsPainter()),
              ),

              Center(
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    // If image isn't ready yet, show a steady greyscale card (no black flash)
                    if (!_imageReady) {
                      return _buildCard(url, grey: true, scale: 0.98);
                    }

                    final spins = 6.0; // readable spins
                    final turns = _spin.value * spins * 2 * 3.1415926;

                    final y = lerpDouble(80, 0, _drop.value)!;
                    final scale = lerpDouble(0.92, 1.0, _impact.value)!;

                    return Transform.translate(
                      offset: Offset(0, y),
                      child: Transform.scale(
                        scale: scale,
                        child: Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()
                            ..setEntry(3, 2, 0.0018)
                            ..rotateY(turns),
                          child: _buildCard(url, grey: !_showColor),
                        ),
                      ),
                    );
                  },
                ),
              ),

              Positioned(
                left: 0,
                right: 0,
                bottom: 32,
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (_, __) {
                    final show = _c.value > 0.66;
                    return AnimatedOpacity(
                      opacity: show ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.16),
                              ),
                            ),
                            child: const Text(
                              'ADDED TO COLLECTION!',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'CARD #${widget.slot} REGISTERED',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.card.name,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(String url, {required bool grey, double scale = 1.0}) {
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: url.isEmpty
          ? Container(
              width: 260,
              height: 360,
              color: const Color(0xFF1F1F1F),
              child: const Center(child: Icon(Icons.style, size: 48)),
            )
          : Image.network(url, width: 260, height: 360, fit: BoxFit.cover),
    );

    final w = grey
        ? ColorFiltered(
            colorFilter: const ColorFilter.matrix(kGreyMatrix),
            child: card,
          )
        : card;

    return Transform.scale(scale: scale, child: w);
  }
}

class AddedToCollectionAnimationScreen extends StatefulWidget {
  final PokemonCardResult card;

  const AddedToCollectionAnimationScreen({super.key, required this.card});

  @override
  State<AddedToCollectionAnimationScreen> createState() =>
      _AddedToCollectionAnimationScreenState();
}

class _AddedToCollectionAnimationScreenState
    extends State<AddedToCollectionAnimationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _spin;
  late final Animation<double> _drop;
  late final Animation<double> _impact;

  Future<void>? _precacheFuture;
  bool _started = false;

  String get _cardUrl => widget.card.imageLarge.isNotEmpty
      ? widget.card.imageLarge
      : widget.card.imageSmall;

  bool get _showColor => _c.value > 0.62;

  @override
  void initState() {
    super.initState();

    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );

    _spin = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.08, 0.78, curve: Curves.easeOutCubic),
    );

    _drop = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.0, 0.62, curve: Curves.easeOutCubic),
    );

    _impact = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.62, 1.0, curve: Curves.elasticOut),
    );

    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        _finishToShowcase();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precacheFuture != null) return; // run once

    final url = _cardUrl.trim();

    _precacheFuture = url.isEmpty
        ? Future.value()
        : precacheImage(NetworkImage(url), context);

    _precacheFuture!.then((_) {
      if (!mounted || _started) return;
      _started = true;
      _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _finishToShowcase() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PostScanOwnedShowcaseScreen(
          card: widget.card,
          returnTarget: const _PostScanReturnTarget.home(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _cardUrl;
    final future = _precacheFuture ?? Future.value();

    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      body: SafeArea(
        child: FutureBuilder<void>(
          future: future,
          builder: (context, snap) {
            final ready = snap.connectionState == ConnectionState.done;

            if (!ready) {
              return Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: _StageLightsPainter()),
                  ),
                  Center(child: _buildCard(url, grey: true, scale: 0.98)),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 24,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Adding to collection...',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }

            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _StageLightsPainter()),
                ),
                Center(
                  child: AnimatedBuilder(
                    animation: _c,
                    builder: (context, _) {
                      final spins = 6.0;
                      final turns = _spin.value * spins * 2 * 3.1415926;

                      final y = lerpDouble(80, 0, _drop.value)!;
                      final scale = lerpDouble(0.92, 1.0, _impact.value)!;

                      return Transform.translate(
                        offset: Offset(0, y),
                        child: Transform.scale(
                          scale: scale,
                          child: Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.identity()
                              ..setEntry(3, 2, 0.0018)
                              ..rotateY(turns),
                            child: _buildCard(url, grey: !_showColor),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 32,
                  child: AnimatedBuilder(
                    animation: _c,
                    builder: (_, __) {
                      final show = _c.value > 0.66;
                      return AnimatedOpacity(
                        opacity: show ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.10),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.16),
                                ),
                              ),
                              child: const Text(
                                'ADDED TO COLLECTION!',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              widget.card.name,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.90),
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCard(String url, {required bool grey, double scale = 1.0}) {
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: url.isEmpty
          ? Container(
              width: 260,
              height: 360,
              color: const Color(0xFF1F1F1F),
              child: const Center(child: Icon(Icons.style, size: 48)),
            )
          : Image.network(url, width: 260, height: 360, fit: BoxFit.cover),
    );

    final w = grey
        ? ColorFiltered(
            colorFilter: const ColorFilter.matrix(kGreyMatrix),
            child: card,
          )
        : card;

    return Transform.scale(scale: scale, child: w);
  }
}

class _StageLightsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF05070D);
    canvas.drawRect(Offset.zero & size, bg);

    // Two soft cones of light
    final p = Paint()
      ..shader =
          RadialGradient(
            colors: [
              const Color(0xFF9CA3AF).withOpacity(0.22),
              Colors.transparent,
            ],
            stops: const [0.0, 1.0],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * 0.28, size.height * 0.02),
              radius: size.width * 0.55,
            ),
          );

    final p2 = Paint()
      ..shader =
          RadialGradient(
            colors: [
              const Color(0xFF9CA3AF).withOpacity(0.18),
              Colors.transparent,
            ],
            stops: const [0.0, 1.0],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * 0.72, size.height * 0.02),
              radius: size.width * 0.55,
            ),
          );

    canvas.drawRect(Offset.zero & size, p);
    canvas.drawRect(Offset.zero & size, p2);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LockedPanel extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const _LockedPanel({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

class _LockedStageCard extends StatelessWidget {
  final int slot;
  final String imageUrl;
  final String label;

  const _LockedStageCard({
    required this.slot,
    required this.imageUrl,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl.isNotEmpty;

    return LayoutBuilder(
      builder: (context, c) {
        // Available height inside the stage area
        final maxH = c.maxHeight;

        // Keep the card readable but NEVER exceed the available height
        final cardH = maxH * 0.82; // card takes most of the stage
        final cardW = cardH * 0.72;

        final pedestalH = maxH * 0.06;
        final pedestalGap = maxH * 0.04;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: cardH,
              width: cardW,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: hasImage
                        ? ColorFiltered(
                            colorFilter: const ColorFilter.matrix(kGreyMatrix),
                            child: Image.network(imageUrl, fit: BoxFit.cover),
                          )
                        : Container(
                            color: const Color(0xFF141824),
                            alignment: Alignment.center,
                            child: Text(
                              label,
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                  ),

                  // vignette
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          radius: 1.2,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.55),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // lock badge
                  Positioned(
                    right: 10,
                    top: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.15),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            'LOCKED',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                              color: Colors.white.withOpacity(0.92),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: pedestalGap),

            // pedestal (scales with available space)
            Container(
              width: cardW * 0.85,
              height: pedestalH,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            SizedBox(height: pedestalH * 0.5),
            Container(
              width: cardW * 0.55,
              height: pedestalH * 0.55,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    Paint cone(double xCenter, double topY, double bottomY, double spread) {
      return Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withOpacity(0.12),
            Colors.white.withOpacity(0.00),
          ],
        ).createShader(Rect.fromLTWH(0, 0, w, h));
    }

    // Left cone
    final p1 = Path()
      ..moveTo(w * 0.18, 0)
      ..lineTo(w * 0.02, h * 0.62)
      ..lineTo(w * 0.34, h * 0.62)
      ..close();
    canvas.drawPath(p1, cone(w * 0.18, 0, h * 0.62, 0.3));

    // Right cone
    final p2 = Path()
      ..moveTo(w * 0.82, 0)
      ..lineTo(w * 0.66, h * 0.62)
      ..lineTo(w * 0.98, h * 0.62)
      ..close();
    canvas.drawPath(p2, cone(w * 0.82, 0, h * 0.62, 0.3));

    // Center glow behind card
    final glow = Paint()
      ..shader = RadialGradient(
        radius: 0.55,
        colors: [Colors.white.withOpacity(0.10), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawCircle(Offset(w * 0.5, h * 0.36), w * 0.42, glow);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CollectedOverlay extends StatefulWidget {
  final CollectedEvent event;
  const _CollectedOverlay({required this.event});

  @override
  State<_CollectedOverlay> createState() => _CollectedOverlayState();
}

class _CollectedOverlayState extends State<_CollectedOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutBack,
  );
  late final Animation<double> _registeredIn = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.35, 1.0, curve: Curves.easeOutBack),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;

    return IgnorePointer(
      child: Container(
        color: Colors.black.withOpacity(0.55),
        child: Center(
          child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.network(
                      e.imageUrl,
                      height: 260,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FadeTransition(
                    opacity: _registeredIn,
                    child: ScaleTransition(
                      scale: _registeredIn,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.25),
                          ),
                        ),
                        child: const Text(
                          'POKÉDEX UPDATED!',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'CARD #${e.slot} COLLECTED!',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    e.cardName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Missing tile supports optional grayscale preview (PokÃ©dex only)
class _MissingSlotTile extends StatelessWidget {
  final int slot;
  final String? previewImageUrl;
  final String? previewName;
  final bool showPreviewLabel;
  final bool isFocused;
  final VoidCallback onTap;

  const _MissingSlotTile({
    required this.slot,
    required this.onTap,
    this.previewImageUrl,
    this.previewName,
    this.showPreviewLabel = false,
    this.isFocused = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final hasPreview = previewImageUrl != null && previewImageUrl!.isNotEmpty;
    final highlightColor = const Color(0xFF7DD3FC);

    return TweenAnimationBuilder<double>(
      key: ValueKey('missing-slot-$slot-$isFocused'),
      tween: Tween<double>(begin: 0, end: isFocused ? 1 : 0),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutBack,
      builder: (context, highlightT, _) {
        final scale = isFocused ? lerpDouble(0.92, 1.0, highlightT)! : 1.0;
        final borderColor = Color.lerp(
          Colors.white.withOpacity(0.08),
          highlightColor.withOpacity(0.9),
          highlightT,
        )!;

        return Transform.scale(
          scale: scale,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Ink(
              decoration: BoxDecoration(
                color: const Color(0xFF1C1F26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.16),
                    blurRadius: 14,
                    offset: const Offset(0, 8),
                  ),
                  if (highlightT > 0)
                    BoxShadow(
                      color: highlightColor.withOpacity(0.24 * highlightT),
                      blurRadius: lerpDouble(12, 24, highlightT)!,
                      spreadRadius: lerpDouble(0, 2, highlightT)!,
                    ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    if (hasPreview)
                      Positioned.fill(
                        child: Opacity(
                          opacity: 0.68,
                          child: ColorFiltered(
                            colorFilter: const ColorFilter.matrix(kGreyMatrix),
                            child: Image.network(
                              previewImageUrl!,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      )
                    else
                      const Center(
                        child: Icon(
                          Icons.style,
                          size: 40,
                          color: Colors.white24,
                        ),
                      ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withOpacity(0.12),
                              Colors.black.withOpacity(0.08),
                              Colors.black.withOpacity(0.58),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 10,
                      child: Container(
                        alignment: Alignment.center,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.45),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$slot',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OwnedSlotTile extends StatelessWidget {
  final int slot;
  final PokemonCardResult card;
  final bool isJustUnlocked;
  final VoidCallback onTap;

  const _OwnedSlotTile({
    required this.slot,
    required this.card,
    this.isJustUnlocked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!isJustUnlocked) {
      return _OwnedSlotTileBody(slot: slot, card: card, onTap: onTap);
    }

    final highlightColor = const Color(0xFF7DD3FC);

    return TweenAnimationBuilder<double>(
      key: ValueKey('owned-slot-$slot-$isJustUnlocked'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutBack,
      builder: (context, highlightT, _) {
        return Transform.scale(
          scale: lerpDouble(0.92, 1.0, highlightT)!,
          child: _OwnedSlotTileBody(
            slot: slot,
            card: card,
            onTap: onTap,
            isJustUnlocked: true,
            highlightT: highlightT,
            highlightColor: highlightColor,
          ),
        );
      },
    );
  }
}

class _OwnedSlotTileBody extends StatelessWidget {
  final int slot;
  final PokemonCardResult card;
  final VoidCallback onTap;
  final bool isJustUnlocked;
  final double highlightT;
  final Color highlightColor;

  const _OwnedSlotTileBody({
    required this.slot,
    required this.card,
    required this.onTap,
    this.isJustUnlocked = false,
    this.highlightT = 0,
    this.highlightColor = const Color(0xFF7DD3FC),
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = Color.lerp(
      Colors.white.withOpacity(0.08),
      highlightColor.withOpacity(0.90),
      highlightT,
    )!;
    final baseShadow = BoxShadow(
      color: Colors.black.withOpacity(0.16),
      blurRadius: 14,
      offset: const Offset(0, 8),
    );
    final pulseShadow = BoxShadow(
      color: highlightColor.withOpacity(0.28 * highlightT),
      blurRadius: lerpDouble(12, 26, highlightT)!,
      spreadRadius: lerpDouble(0, 2, highlightT)!,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
          boxShadow: [baseShadow, if (highlightT > 0) pulseShadow],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: card.imageSmall.isEmpty
                    ? Container(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.image_not_supported),
                      )
                    : Image.network(
                        card.imageSmall,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                        cacheWidth: 360,
                      ),
              ),
            ),
            if (highlightT > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: highlightColor.withOpacity(0.65 * highlightT),
                        width: lerpDouble(1.2, 2.6, highlightT)!,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: highlightColor.withOpacity(0.22 * highlightT),
                          blurRadius: 20,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withOpacity(0.48),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$slot',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isJustUnlocked
                      ? Color.lerp(
                          const Color(0xFF0F7B43).withOpacity(0.9),
                          const Color(0xFF0369A1).withOpacity(0.95),
                          highlightT,
                        )
                      : const Color(0xFF0F7B43).withOpacity(0.9),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white.withOpacity(0.10)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isJustUnlocked ? Icons.auto_awesome : Icons.check_circle,
                      size: 12,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isJustUnlocked ? 'NEW' : 'OWNED',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: _SlotStateFooter(
                title: card.name,
                subtitle: '#${card.number}',
                locked: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotStateFooter extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool locked;

  const _SlotStateFooter({
    required this.title,
    required this.subtitle,
    required this.locked,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.42),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withOpacity(locked ? 0.82 : 0.92),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withOpacity(locked ? 0.64 : 0.78),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------------------------- DETAILS + GRADING --------------------------- */

class PokemonCardDetailsScreen extends StatefulWidget {
  final PokemonCardResult card;
  final String? expectedSetId;
  final int? expectedSlot;
  final bool compactAddMode;
  final bool readOnly;

  const PokemonCardDetailsScreen({
    super.key,
    required this.card,
    this.expectedSetId,
    this.expectedSlot,
    this.compactAddMode = false,
    this.readOnly = false,
  });

  @override
  State<PokemonCardDetailsScreen> createState() =>
      _PokemonCardDetailsScreenState();
}

class _PokemonCardDetailsScreenState extends State<PokemonCardDetailsScreen> {
  String? _selectedFinish;
  int _grade = 8;
  late Future<PokemonCardResult?> _fullFuture;

  @override
  void initState() {
    super.initState();
    _fullFuture = widget.compactAddMode || widget.readOnly
        ? Future.value(null)
        : PokemonTcgApi().fetchCardById(widget.card.id);

    if (widget.card.finishes.isNotEmpty) {
      const preferred = ['normal', 'holofoil', 'reverseHolofoil'];
      for (final p in preferred) {
        if (widget.card.finishes.containsKey(p)) {
          _selectedFinish = p;
          break;
        }
      }
      _selectedFinish ??= widget.card.finishes.keys.first;
    }
  }

  String _money(double? v) => v == null ? '-' : '\$${v.toStringAsFixed(2)}';

  String? _defaultFinishFor(Map<String, PriceRow> finishes) {
    if (finishes.isEmpty) return null;
    const preferred = ['normal', 'holofoil', 'reverseHolofoil'];
    for (final p in preferred) {
      if (finishes.containsKey(p)) return p;
    }
    return finishes.keys.first;
  }

  double? _baseMarket(PokemonCardResult card, String? finish) {
    if (finish == null) return card.bestMarket;
    return card.finishes[finish]?.market ?? card.bestMarket;
  }

  double? _estimatedValue(PokemonCardResult card, String? finish) {
    final base = _baseMarket(card, finish);
    if (base == null) return null;
    return base * (_grade / 10.0);
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  bool _slotAcceptsCard({
    required PokemonCardResult card,
    required String expectedSetId,
    required int expectedSlot,
  }) {
    final cardSet = card.setId.trim();
    final cardNum = int.tryParse(card.number.replaceAll(RegExp(r'[^0-9]'), ''));
    return cardSet == expectedSetId && cardNum == expectedSlot;
  }

  Future<PokemonCardResult> _attachMarketValue(PokemonCardResult card) async {
    if (card.marketValue != null) return card;

    final query = buildEbayQuery(
      name: card.name,
      setName: card.setName,
      number: card.number,
      printedTotal: card.setPrintedTotal,
      mode: EbayMode.raw,
    );

    final marketValue = await fetchEbayMarketValue(query: query);
    if (marketValue == null) return card;
    return card.copyWith(marketValue: marketValue);
  }

  Future<void> _enrichSavedCardMarketValue(PokemonCardResult card) async {
    if (card.marketValue != null) return;

    final enrichedCard = await _attachMarketValue(card);
    final marketValue = enrichedCard.marketValue;
    if (marketValue == null) return;

    collectionStore.updateCardMarketValueIfMissing(
      cardId: card.id,
      marketValue: marketValue,
    );
  }

  Future<void> _saveCard(PokemonCardResult card) async {
    if (!_hasPersistentCollectionAccess(FirebaseAuth.instance.currentUser)) {
      if (!mounted) return;
      await _showAccountRequiredToSavePrompt(context);
      return;
    }

    final expectedSetId = widget.expectedSetId;
    final expectedSlot = widget.expectedSlot;
    final fromPokedex = expectedSetId != null && expectedSlot != null;
    final fromScanAddFlow = fromPokedex || widget.compactAddMode;

    final already = collectionStore.containsCardId(card.id);
    if (already) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already in your collection.')),
      );

      if (!fromPokedex && widget.compactAddMode) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => OwnedCardShowcaseScreen(card: card),
          ),
        );
      }
      return;
    }

    if (fromPokedex) {
      final ok = _slotAcceptsCard(
        card: card,
        expectedSetId: expectedSetId!,
        expectedSlot: expectedSlot!,
      );
      if (!ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Wrong card for this Pokédex slot. Please rescan.'),
          ),
        );
        return;
      }
    }

    final cardToSave = card;

    if (fromScanAddFlow) {
      _rewardOverlayGate.hold();
    }
    collectionStore.addCard(cardToSave);
    unawaited(_enrichSavedCardMarketValue(cardToSave));

    if (fromPokedex) {
      collectionStore.emitCollected(
        CollectedEvent(
          setKey: expectedSetId!,
          slot: expectedSlot!,
          cardName: cardToSave.name,
          imageUrl: cardToSave.imageLarge.isNotEmpty
              ? cardToSave.imageLarge
              : cardToSave.imageSmall,
        ),
      );
    }

    if (!mounted) return;
    setState(() {});

    if (fromPokedex) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PokedexRegisterAnimationScreen(
            card: cardToSave,
            setKey: expectedSetId!,
            slot: expectedSlot!,
          ),
        ),
      );
      return;
    }

    if (widget.compactAddMode) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => AddedToCollectionAnimationScreen(card: cardToSave),
        ),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => OwnedCardShowcaseScreen(card: cardToSave),
      ),
    );
  }

  Widget _glassCard({
    required Widget child,
    EdgeInsetsGeometry? padding,
    Color? accentColor,
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accentColor?.withOpacity(0.12) ?? Colors.white.withOpacity(0.065),
            Colors.white.withOpacity(0.022),
          ],
        ),
        border: Border.all(
          color:
              accentColor?.withOpacity(0.20) ?? Colors.white.withOpacity(0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.24),
            blurRadius: 22,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildHero(PokemonCardResult card, {Color? accentColor}) {
    return _glassCard(
      accentColor: accentColor,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: AspectRatio(
                aspectRatio: 63 / 88,
                child: PokemonCardShowcase(card: card, animate: true),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            card.name.isEmpty ? 'Unknown Card' : card.name,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              height: 1.04,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${card.setName} - #${card.number}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.74),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrowseNotice({required Color accentColor}) {
    return _glassCard(
      accentColor: accentColor,
      padding: const EdgeInsets.all(16),
      child: Text(
        'Manual Search is browse-only. Scan cards to add them to your collection.',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withOpacity(0.80),
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
      ),
    );
  }

  Uri _browseOnlyEbaySearchUrl(PokemonCardResult card) {
    final q = Uri.encodeComponent(
      '${card.name} ${card.number} ${card.setName}',
    );
    return Uri.parse('https://www.ebay.com/sch/i.html?_nkw=$q');
  }

  Uri _browseOnlyEbaySoldUrl(PokemonCardResult card) {
    final q = Uri.encodeComponent(
      '${card.name} ${card.number} ${card.setName}',
    );
    return Uri.parse(
      'https://www.ebay.com/sch/i.html?_nkw=$q&LH_Sold=1&LH_Complete=1',
    );
  }

  Widget _buildReadOnlyMarketSection(
    PokemonCardResult card, {
    required Color accentColor,
    required String ebayQuery,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _glassCard(
          accentColor: accentColor,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'eBay',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                'Open eBay for active or sold listings, or browse the inline preview below.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.76),
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () =>
                      _openLink(_browseOnlyEbaySearchUrl(card).toString()),
                  icon: const Icon(Icons.shopping_bag_outlined),
                  label: const Text('View active listings on eBay'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      _openLink(_browseOnlyEbaySoldUrl(card).toString()),
                  icon: const Icon(Icons.query_stats),
                  label: const Text('View sold listings on eBay'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        EbayListingPreviewSection(
          query: ebayQuery,
          accentColor: accentColor,
          title: 'eBay Preview',
        ),
      ],
    );
  }

  Widget _imageFallback() {
    return Container(
      color: Colors.white.withOpacity(0.05),
      child: const Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 40,
          color: Colors.white54,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PokemonCardResult?>(
      future: _fullFuture,
      builder: (context, snap) {
        final card = snap.data ?? widget.card;
        final accentColor = cardAccentColor(card);
        final ebayQuery = buildEbayQuery(
          name: card.name,
          setName: card.setName,
          number: card.number,
          printedTotal: card.setPrintedTotal,
          mode: EbayMode.raw,
        );
        final finish = _selectedFinish ?? _defaultFinishFor(card.finishes);
        final prices = finish == null ? null : card.finishes[finish];
        final base = _baseMarket(card, finish);
        final est = _estimatedValue(card, finish);
        final saved = collectionStore.containsCardId(card.id);
        final loading =
            !widget.compactAddMode &&
            !widget.readOnly &&
            snap.connectionState != ConnectionState.done;
        final pricingError =
            !widget.compactAddMode && !widget.readOnly && snap.hasError;

        if (widget.readOnly) {
          return Scaffold(
            backgroundColor: const Color(0xFF071018),
            appBar: AppBar(title: const Text('Card Details')),
            body: Stack(
              children: [
                Positioned.fill(
                  child: _CardDetailBackdrop(accentColor: accentColor),
                ),
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildHero(card, accentColor: accentColor),
                    const SizedBox(height: 16),
                    _buildBrowseNotice(accentColor: accentColor),
                    const SizedBox(height: 16),
                    _buildReadOnlyMarketSection(
                      card,
                      accentColor: accentColor,
                      ebayQuery: ebayQuery,
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        return Scaffold(
          backgroundColor: const Color(0xFF071018),
          appBar: AppBar(
            title: Text(
              widget.compactAddMode ? 'Confirm Card' : 'Card Details',
            ),
          ),
          body: Stack(
            children: [
              Positioned.fill(
                child: _CardDetailBackdrop(accentColor: accentColor),
              ),
              ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: LinearProgressIndicator(),
                    ),
                  if (pricingError)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Pricing temporarily unavailable. Showing card info only.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  _buildHero(card, accentColor: accentColor),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 54,
                    child: ElevatedButton.icon(
                      icon: Icon(saved ? Icons.check : Icons.add),
                      label: Text(saved ? 'Added' : 'Add to collection'),
                      onPressed: saved ? null : () => _saveCard(card),
                    ),
                  ),
                  if (widget.compactAddMode) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 54,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Not your card? Rescan'),
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ScanScreen(
                                cameras: gCameras,
                                expectedSetId: widget.expectedSetId,
                                expectedSlot: widget.expectedSlot,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 16),
                    if (card.finishes.isNotEmpty) ...[
                      const Text(
                        'Finish',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: card.finishes.keys.map((k) {
                          return ChoiceChip(
                            label: Text(k),
                            selected: k == finish,
                            onSelected: (_) =>
                                setState(() => _selectedFinish = k),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                    ],
                    _glassCard(
                      accentColor: accentColor,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Pricing (TCGplayer)',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _kv(
                            'Market',
                            _money(prices?.market ?? card.bestMarket),
                          ),
                          _kv('Low', _money(prices?.low)),
                          _kv('Mid', _money(prices?.mid)),
                          _kv('High', _money(prices?.high)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    EbayListingPreviewSection(
                      query: ebayQuery,
                      accentColor: accentColor,
                      title: 'eBay Preview',
                    ),
                    const SizedBox(height: 16),
                    _glassCard(
                      accentColor: accentColor,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Condition (1-10)',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text('Selected grade: $_grade'),
                          Slider(
                            value: _grade.toDouble(),
                            min: 1,
                            max: 10,
                            divisions: 9,
                            label: '$_grade',
                            onChanged: (v) =>
                                setState(() => _grade = v.round()),
                          ),
                          Text(
                            base == null
                                ? 'No market price available for estimate.'
                                : 'Estimated value @ grade $_grade: ${_money(est)}',
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ConditionGuideScreen(
                                    initialGrade: _grade,
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.info_outline),
                            label: const Text('How to grade (guide)'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (card.tcgplayerUrl != null &&
                        card.tcgplayerUrl!.isNotEmpty)
                      SizedBox(
                        height: 52,
                        child: OutlinedButton.icon(
                          onPressed: () => _openLink(card.tcgplayerUrl!),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open TCGplayer listing'),
                        ),
                      ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _ReadOnlyEbaySection extends StatelessWidget {
  final PokemonCardResult card;
  final Color accentColor;
  final String ebayQuery;

  const _ReadOnlyEbaySection({
    required this.card,
    required this.accentColor,
    required this.ebayQuery,
  });

  String _money(double? v) => v == null ? '-' : '\$${v.toStringAsFixed(2)}';

  Uri _ebaySearchUrl() {
    final q = Uri.encodeComponent(
      '${card.name} ${card.number} ${card.setName}',
    );
    return Uri.parse('https://www.ebay.com/sch/i.html?_nkw=$q');
  }

  Uri _ebaySoldUrl() {
    final q = Uri.encodeComponent(
      '${card.name} ${card.number} ${card.setName}',
    );
    return Uri.parse(
      'https://www.ebay.com/sch/i.html?_nkw=$q&LH_Sold=1&LH_Complete=1',
    );
  }

  Future<void> _openExternal(BuildContext context, Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open eBay')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accentColor.withOpacity(0.18)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accentColor.withOpacity(0.12),
                Colors.white.withOpacity(0.03),
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'eBay Market',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _MiniPriceTile(
                      label: 'Tracked',
                      value: _money(card.marketValue ?? card.bestMarket),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MiniPriceTile(
                      label: 'Set',
                      value: card.setName.isEmpty ? '-' : card.setName,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Glance at recent eBay pricing without leaving the app.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.76),
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () => _openExternal(context, _ebaySearchUrl()),
                  icon: const Icon(Icons.shopping_bag_outlined),
                  label: const Text('View active listings on eBay'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => _openExternal(context, _ebaySoldUrl()),
                  icon: const Icon(Icons.query_stats),
                  label: const Text('View sold listings on eBay'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        EbayListingPreviewSection(
          query: ebayQuery,
          accentColor: accentColor,
          title: 'Inline eBay Preview',
        ),
      ],
    );
  }
}

class _CardDetailBackdrop extends StatelessWidget {
  final Color accentColor;

  const _CardDetailBackdrop({required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Container(color: const Color(0xFF071018)),
          Positioned(
            top: -120,
            right: -40,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    accentColor.withOpacity(0.22),
                    accentColor.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: -80,
            top: 180,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Colors.white.withOpacity(0.06), Colors.transparent],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniPriceTile extends StatelessWidget {
  final String label;
  final String value;

  const _MiniPriceTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.68),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class ConditionGuideScreen extends StatelessWidget {
  final int initialGrade;
  const ConditionGuideScreen({super.key, required this.initialGrade});

  String _label(int g) {
    if (g >= 10) return 'Gem Mint (PSA 10)';
    if (g == 9) return 'Mint (PSA 9)';
    if (g == 8) return 'Near Mint-Mint (PSA 8)';
    if (g == 7) return 'Near Mint (PSA 7)';
    if (g == 6) return 'Excellent-Mint (PSA 6)';
    if (g == 5) return 'Excellent (PSA 5)';
    if (g == 4) return 'Very Good-Excellent (PSA 4)';
    if (g == 3) return 'Very Good (PSA 3)';
    if (g == 2) return 'Good (PSA 2)';
    return 'Poor (PSA 1)';
  }

  String _desc(int g) {
    if (g >= 10) return 'Perfect corners, edges, surface, and centering.';
    if (g == 9) return 'Almost flawless, tiny imperfections.';
    if (g == 8) return 'Minor whitening or surface wear.';
    if (g == 7) return 'Noticeable whitening, minor scratches/print lines.';
    if (g == 6)
      return 'Moderate wear, small crease possible, still presentable.';
    if (g == 5)
      return 'Clear wear, whitening, surface scratches, possible small crease.';
    if (g == 4) return 'Heavy wear, corner rounding, surface damage.';
    if (g == 3)
      return 'Major wear, creases, edge chipping, strong surface issues.';
    if (g == 2) return 'Severe wear/damage, multiple creases.';
    return 'Very damaged (tears, heavy creasing, ink, etc.).';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Grading Guide')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: 10,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final g = 10 - i;
          return Card(
            child: ListTile(
              title: Text('Grade $g - ${_label(g)}'),
              subtitle: Text(_desc(g)),
              trailing: g == initialGrade
                  ? const Icon(Icons.check_circle)
                  : null,
            ),
          );
        },
      ),
    );
  }
}

/* ----------------------------- RECOGNIZING ----------------------------- */

class RecognizingScreen extends StatefulWidget {
  final String photoPath;

  /// If provided, this scan is "slot-locked" (PokÃ©dex flow)
  final String? expectedSetId;
  final int? expectedSlot;

  const RecognizingScreen({
    super.key,
    required this.photoPath,
    this.expectedSetId,
    this.expectedSlot,
  });

  @override
  State<RecognizingScreen> createState() => _RecognizingScreenState();
}

class _RecognizingScreenState extends State<RecognizingScreen> {
  bool _loading = true;
  String? _error;

  final _nameCtrl = TextEditingController();
  final _numCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _runAll();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _numCtrl.dispose();
    super.dispose();
  }

  /* ----------------------------- helpers ----------------------------- */

  bool _isLabelOnlyName(String name) {
    final l = name.trim().toLowerCase();
    return l == 'trainer' || l == 'traner' || l == 'pokemon' || l == 'energy';
  }

  bool _matchesExpected(PokemonCardResult card) {
    final expectedSetId = widget.expectedSetId;
    final expectedSlot = widget.expectedSlot;
    if (expectedSetId == null || expectedSlot == null) return true;

    final cardSet = card.setId.trim();
    final cardNum = int.tryParse(card.number.replaceAll(RegExp(r'[^0-9]'), ''));
    return cardSet == expectedSetId && cardNum == expectedSlot;
  }

  Future<PokemonCardResult> _cardWithMarketValue(PokemonCardResult card) async {
    if (card.marketValue != null) return card;

    final query = buildEbayQuery(
      name: card.name,
      setName: card.setName,
      number: card.number,
      printedTotal: card.setPrintedTotal,
      mode: EbayMode.raw,
    );

    final marketValue = await fetchEbayMarketValue(query: query);
    if (marketValue == null) return card;
    return card.copyWith(marketValue: marketValue);
  }

  Future<void> _enrichSavedCardMarketValue(PokemonCardResult card) async {
    if (card.marketValue != null) return;

    final enrichedCard = await _cardWithMarketValue(card);
    final marketValue = enrichedCard.marketValue;
    if (marketValue == null) return;

    collectionStore.updateCardMarketValueIfMissing(
      cardId: card.id,
      marketValue: marketValue,
    );
  }

  bool _hasLetters(String s) => RegExp(r'[A-Za-z]').hasMatch(s);

  String _normalizeOcrCollectorNumber(String raw) {
    var s = raw.toUpperCase().trim();
    s = s.replaceAll(RegExp(r'[^A-Z0-9]'), '');

    final promoMatch = RegExp(r'^(SVP|SWSH)([0-9]{1,3})$').firstMatch(s);
    if (promoMatch != null) {
      return '${promoMatch.group(1)}${promoMatch.group(2)}';
    }

    final suffixDigits = RegExp(r'([0-9]{1,4})$').firstMatch(s);
    if (suffixDigits != null) {
      final parsed = int.tryParse(suffixDigits.group(1)!);
      if (parsed != null && parsed > 0) return parsed.toString();
    }

    return '';
  }

  String _flattenRaw(String raw) {
    return raw
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'[Il]'), '1')
        .replaceAll('O', '0');
  }

  ({String num, String total})? _extractCollectorFraction(String flat) {
    final m = RegExp(
      r'(?<!\d)(\d{1,4})\s*[/\|\-â€“â€”]\s*(\d{2,4})(?!\d)',
    ).firstMatch(flat);
    if (m == null) return null;

    final n = (m.group(1) ?? '').trim();
    final t = (m.group(2) ?? '').trim();
    if (n.isEmpty || t.isEmpty) return null;
    final normalizedNum = int.tryParse(n)?.toString() ?? n;
    final normalizedTotal = int.tryParse(t)?.toString() ?? t;
    return (num: normalizedNum, total: normalizedTotal);
  }

  /* ----------------------------- main flow ----------------------------- */

  Future<void> _runAll() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final guess = await PokemonOcr.recognizeFromImagePath(widget.photoPath);

      final rawText = guess.rawText ?? '';
      final flat = _flattenRaw(rawText);
      final hp = guess.hp;
      final setCode = (guess.setCode ?? '').trim().toUpperCase();
      final setCodeSource = (guess.setCodeSource ?? '').trim();

      // ---------- NAME ----------
      final rawName = (guess.name ?? '').trim();
      final usedName = _isLabelOnlyName(rawName)
          ? (PokemonOcr.extractTrainerTitleFromRaw(rawText) ?? '')
          : rawName;

      // ---------- NUMBER / TOTAL ----------
      final rawNumber = (guess.number ?? '').trim();
      String? numOnly;
      String setTotalStr = (guess.setTotal ?? '').trim();

      if (rawNumber.isNotEmpty) {
        if (rawNumber.contains('/')) {
          final parts = rawNumber.split('/');
          final normalized = _normalizeOcrCollectorNumber(parts.first.trim());
          numOnly = normalized.isEmpty ? null : normalized;
          if (setTotalStr.isEmpty && parts.length > 1) {
            setTotalStr = parts[1].trim();
          }
        } else {
          final normalized = _normalizeOcrCollectorNumber(rawNumber.trim());
          numOnly = normalized.isEmpty ? null : normalized;
        }
      }

      // ignore: avoid_print
      print(
        'SCAN DEBUG [parsed-number] raw="$rawNumber" normalized="${numOnly ?? ''}"',
      );

      if (numOnly != null && numOnly!.trim().isEmpty) numOnly = null;
      if (setTotalStr.trim().isEmpty) setTotalStr = '';

      final frac = flat.isNotEmpty ? _extractCollectorFraction(flat) : null;
      if (frac != null) {
        final current = (numOnly ?? '').trim();
        if (current.isEmpty || _hasLetters(current)) {
          numOnly = frac.num;
        }
        if (setTotalStr.trim().isEmpty) setTotalStr = frac.total;
      }

      if (numOnly != null && numOnly!.trim().isEmpty) numOnly = null;
      if (setTotalStr.trim().isEmpty) setTotalStr = '';

      // ---------- SVP PROMO DETECTION ----------
      final svpDigitsFromNumber = PokemonOcr.extractSvpNumberFromRaw(rawText);
      final svpDigitsFromSignature = PokemonOcr.detectSvpSlotBySignature(
        rawText,
      );
      final int? svpDigits = svpDigitsFromNumber ?? svpDigitsFromSignature;

      // ignore: avoid_print
      print(
        'ðŸ§· SVP DEBUG â†’ fromNumber=$svpDigitsFromNumber fromSignature=$svpDigitsFromSignature chosen=$svpDigits',
      );

      final bool isSvpDetected = svpDigits != null;
      final bool isSvpFlow = widget.expectedSetId == 'svp' || isSvpDetected;

      if (isSvpFlow && svpDigits != null) {
        numOnly = 'SVP$svpDigits';
        if (setTotalStr.isEmpty) setTotalStr = '102';
      }

      // ---------- PROMO CODE GUARD (non-SVP) ----------
      if (!isSvpFlow && numOnly != null && _hasLetters(numOnly!)) {
        numOnly = null;
      }

      // ---------- SLOT LOCKING ----------
      final bool isSlotLocked =
          widget.expectedSetId != null && widget.expectedSlot != null;

      final String? expectedSetId =
          (widget.expectedSetId != null &&
              widget.expectedSetId!.trim().isNotEmpty)
          ? widget.expectedSetId!.trim()
          : null;

      // IMPORTANT: If slot-locked, don't pass expectedSlot into worker search.
      final int? expectedSlot = isSlotLocked ? null : widget.expectedSlot;

      // ignore: avoid_print
      print(
        'SCAN DEBUG [ocr] rawName="$rawName" usedName="$usedName" '
        'stage="${guess.stage ?? ''}" rawNumber="$rawNumber" '
        'parsedNumber="${numOnly ?? ''}" '
        'setTotal=${setTotalStr.isEmpty ? "null" : setTotalStr} '
        'setCode="${setCode.isEmpty ? '' : setCode}" '
        'setCodeSource="${setCodeSource.isEmpty ? '' : setCodeSource}" '
        'hp=${hp ?? 'null'} expectedSetId="${expectedSetId ?? ''}" '
        'expectedSlot=${expectedSlot ?? 'null'} svpDigits=${svpDigits ?? 'null'}',
      );
      // ignore: avoid_print
      print(
        'SCAN DEBUG [recognizer-handoff] name="$usedName" '
        'number="${numOnly ?? ''}" numberSource="${guess.numberSource ?? ''}" '
        'setTotal="${setTotalStr.isEmpty ? '' : setTotalStr}" '
        'setCode="${setCode.isEmpty ? '' : setCode}" '
        'setCodeSource="${setCodeSource.isEmpty ? '' : setCodeSource}" '
        'hp=${hp ?? 'null'} rawTextLen=${rawText.length}',
      );

      if (usedName.trim().isEmpty && (numOnly == null || numOnly!.isEmpty)) {
        // ignore: avoid_print
        print(
          'SCAN DEBUG [ocr-empty] no usable name/number; proceeding with raw-text fallback lookup',
        );
      }

      // ---------- SEARCH ----------
      final api = PokemonTcgApi();
      final pick = await api.searchCardsReliable(
        name: usedName,
        number: numOnly,
        numberSource: guess.numberSource,
        imagePath: widget.photoPath,
        setTotal: setTotalStr,
        setCode: setCode.isEmpty ? null : setCode,
        setCodeSource: setCodeSource.isEmpty ? null : setCodeSource,
        hp: hp,
        rawText: rawText,
        expectedSetId: expectedSetId,
        expectedSlot: expectedSlot,
        svpSlot: svpDigits,
      );

      // ignore: avoid_print
      print(
        'SCAN DEBUG [recognizer-pick] strategy="${pick.strategy}" '
        'best="${pick.best?.name ?? ''}" '
        'bestNumber="${pick.best?.number ?? ''}" '
        'bestSet="${pick.best?.setName ?? ''}" '
        'candidateCount=${pick.candidates.length}',
      );

      if (!mounted) return;

      // ---------- BEST MATCH ----------
      if (pick.best != null) {
        final card = pick.best!;

        if (!_matchesExpected(card)) {
          await _showWrongCardDialog(card);
          return;
        }

        // Slot-locked flow (PokÃ©dex)
        if (isSlotLocked) {
          if (!_hasPersistentCollectionAccess(
            FirebaseAuth.instance.currentUser,
          )) {
            await _showAccountRequiredToSavePrompt(context);
            return;
          }

          final cardToSave = card;

          _rewardOverlayGate.hold();
          collectionStore.addCard(cardToSave);
          unawaited(_enrichSavedCardMarketValue(cardToSave));
          collectionStore.emitCollected(
            CollectedEvent(
              setKey: widget.expectedSetId!,
              slot: widget.expectedSlot!,
              cardName: cardToSave.name,
              imageUrl: cardToSave.imageLarge.isNotEmpty
                  ? cardToSave.imageLarge
                  : cardToSave.imageSmall,
            ),
          );

          if (!mounted) return;

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PokedexRegisterAnimationScreen(
                card: cardToSave,
                setKey: widget.expectedSetId!,
                slot: widget.expectedSlot!,
              ),
            ),
          );
          return;
        }

        // Non-slot-locked: prevent duplicates
        final already = collectionStore.containsCardId(card.id);
        if (already) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Already in your collection.')),
          );
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => OwnedCardShowcaseScreen(card: card),
            ),
          );
          return;
        }

        // Non-slot-locked: go to clean confirm screen (no pricing/toggle)
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PokemonCardDetailsScreen(
              card: card,
              expectedSetId: widget.expectedSetId,
              expectedSlot: widget.expectedSlot,
              compactAddMode: true,
            ),
          ),
        );
        return;
      }

      // ---------- SLOT-LOCK FAILURE ----------
      if (isSlotLocked) {
        setState(() {
          _error =
              'Could not confirm this is the correct card for slot #${widget.expectedSlot}. Try again.';
        });
        return;
      }

      // ---------- FALLBACK LIST ----------
      _goToResults(
        name: usedName,
        number: numOnly,
        prefetched: pick.candidates,
        scannerFallback: true,
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('âŒ Recognizing failed: $e');
      // ignore: avoid_print
      print(st);

      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /* ----------------------------- navigation ----------------------------- */

  void _goToResults({
    required String name,
    String? number,
    List<PokemonCardResult>? prefetched,
    bool scannerFallback = false,
  }) {
    final hasSomething =
        name.trim().isNotEmpty || (number != null && number.trim().isNotEmpty);

    if (!hasSomething) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ManualSearchScreen()),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SearchResultsScreen(
          name: name.trim(),
          set: null,
          number: (number != null && number.trim().isNotEmpty)
              ? number.trim()
              : null,
          prefetched: prefetched,
          browseOnly: false,
          scannerFallback: scannerFallback,
          expectedSetId: widget.expectedSetId,
          expectedSlot: widget.expectedSlot,
        ),
      ),
    );
  }

  Future<void> _showWrongCardDialog(PokemonCardResult found) async {
    final expectedSetId = widget.expectedSetId;
    final expectedSlot = widget.expectedSlot;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wrong card scanned'),
        content: Text(
          'You started a slot-locked scan.\n\n'
          'Expected: #$expectedSlot ($expectedSetId)\n'
          'Found: #${found.number} (${found.setId})\n'
          '${found.name}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Try again'),
          ),
        ],
      ),
    );

    if (mounted) Navigator.pop(context);
  }

  void _manualSearch() {
    final name = _nameCtrl.text.trim();
    final number = _numCtrl.text.trim();

    if (name.isEmpty && number.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Type a name or number to search.')),
      );
      return;
    }

    _goToResults(name: name, number: number);
  }

  /* ----------------------------- UI ----------------------------- */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recognizing...')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Reading card text...'),
                  ],
                ),
              )
            : Column(
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _numCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Card number (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _runAll,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry OCR'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _manualSearch,
                          icon: const Icon(Icons.search),
                          label: const Text('Search'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/* ------------------------- POKEDEX REGISTERED POPUP ------------------------- */

Future<void> showPokedexRegistered(
  BuildContext context, {
  required PokemonCardResult card,
  int? slot,
  String? setNameOverride,
}) async {
  HapticFeedback.mediumImpact();

  final rootNav = Navigator.of(context, rootNavigator: true);

  Future.delayed(const Duration(milliseconds: 1150), () {
    if (rootNav.canPop()) rootNav.pop();
  });

  await showGeneralDialog(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'registered',
    barrierColor: Colors.black.withOpacity(0.55),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) {
      final number =
          slot ?? int.tryParse(card.number.replaceAll(RegExp(r'[^0-9]'), ''));
      final subtitle =
          setNameOverride ?? (card.setName.isNotEmpty ? card.setName : '-');

      return SafeArea(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 320,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 30,
                    color: Colors.black.withOpacity(0.45),
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'Pokédex Registered',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 64,
                          height: 88,
                          color: Colors.white.withOpacity(0.06),
                          child:
                              (card.imageSmall.isEmpty &&
                                  card.imageLarge.isEmpty)
                              ? const Icon(Icons.style)
                              : Image.network(
                                  card.imageSmall.isNotEmpty
                                      ? card.imageSmall
                                      : card.imageLarge,
                                  fit: BoxFit.cover,
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              card.name.isEmpty ? 'Registered' : card.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              number == null
                                  ? subtitle
                                  : '$subtitle - #$number',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.78),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.check_circle, size: 28),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class AnimatedBackground extends StatefulWidget {
  const AnimatedBackground({super.key});

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 10))
      ..repeat(reverse: true);

    _t = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final a = Alignment.lerp(
          const Alignment(-0.8, -0.6),
          const Alignment(0.9, 0.8),
          _t.value,
        )!;
        final b = Alignment.lerp(
          const Alignment(0.9, -0.8),
          const Alignment(-0.8, 0.9),
          _t.value,
        )!;

        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: a,
              end: b,
              colors: const [
                Color(0xFF071622),
                Color(0xFF062B33),
                Color(0xFF040B12),
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.lerp(
                  const Alignment(-0.2, -0.4),
                  const Alignment(0.6, 0.5),
                  _t.value,
                )!,
                radius: 1.2,
                colors: const [Color(0x2200E5FF), Color(0x00000000)],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        );
      },
    );
  }
}

class FloatingFeaturedCardBg extends StatefulWidget {
  final String imageUrl;
  const FloatingFeaturedCardBg({super.key, required this.imageUrl});

  @override
  State<FloatingFeaturedCardBg> createState() => _FloatingFeaturedCardBgState();
}

class _FloatingFeaturedCardBgState extends State<FloatingFeaturedCardBg>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 8))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_c.value);

        final dy = lerpDouble(-10, 14, t)!;
        final rot = lerpDouble(-0.08, 0.06, t)!; // radians
        final scale = lerpDouble(1.02, 1.06, t)!;

        return IgnorePointer(
          child: Opacity(
            opacity: 0.14, // pushed back more (was 0.22)
            child: Transform.translate(
              offset: Offset(0, dy),
              child: Transform.rotate(
                angle: rot,
                child: Transform.scale(
                  scale: scale,
                  child: Align(
                    alignment: const Alignment(0.75, -0.65), // moved up/left
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Stack(
                        children: [
                          Image.network(
                            widget.imageUrl,
                            width: 260,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.high,
                          ),

                          // Blur it so it becomes â€œartâ€, not readable text
                          Positioned.fill(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                              child: const SizedBox(),
                            ),
                          ),

                          // Darken it slightly so UI stays dominant
                          Positioned.fill(
                            child: Container(
                              color: Colors.black.withOpacity(0.35),
                            ),
                          ),

                          // Soft highlight edge for premium feel
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white24),
                                borderRadius: BorderRadius.circular(22),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
