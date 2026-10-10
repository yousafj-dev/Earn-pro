import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const EarningApp());
}

class EarningApp extends StatelessWidget {
  const EarningApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Earning App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1665D8)),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.data == null) return const AuthPage();
        return const DashboardPage();
      },
    );
  }
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _isSignup = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = FirebaseAuth.instance;
      if (_isSignup) {
        final credential = await auth.createUserWithEmailAndPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
        final user = credential.user!;
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'displayName': _name.text.trim(),
          'email': user.email,
          'createdAt': FieldValue.serverTimestamp(),
          'referralCode': user.uid.substring(0, 8).toUpperCase(),
          'role': 'user',
          'accountStatus': 'active',
        });
      } else {
        await auth.signInWithEmailAndPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _authMessage(e.code));
    } catch (_) {
      setState(() => _error =
          'Account request failed. Check Firebase setup and Firestore rules, then try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _authMessage(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'This email is already registered. Try logging in.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'weak-password':
        return 'Choose a stronger password (at least 6 characters).';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email or password is incorrect.';
      case 'network-request-failed':
        return 'Network error. Check your internet connection.';
      default:
        return 'Could not authenticate ($code). Check Firebase settings.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.account_balance_wallet_outlined, size: 52),
                      const SizedBox(height: 12),
                      Text(
                        _isSignup ? 'Create your account' : 'Welcome back',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Earn rewards by completing verified sponsored tasks.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      if (_isSignup) ...[
                        TextFormField(
                          controller: _name,
                          decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
                          validator: (v) => (v == null || v.trim().length < 2)
                              ? 'Enter your name'
                              : null,
                        ),
                        const SizedBox(height: 14),
                      ],
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                        validator: (v) => (v == null || !v.contains('@'))
                            ? 'Enter a valid email'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        autofillHints: _isSignup
                            ? const [AutofillHints.newPassword]
                            : const [AutofillHints.password],
                        decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                        validator: (v) => (v == null || v.length < 6)
                            ? 'Use at least 6 characters'
                            : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(_isSignup ? 'Sign up' : 'Log in'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _isSignup = !_isSignup;
                                  _error = null;
                                }),
                        child: Text(_isSignup
                            ? 'Already have an account? Log in'
                            : 'New here? Create an account'),
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
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  Future<void> _logout() => FirebaseAuth.instance.signOut();

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    final profile = FirebaseFirestore.instance.collection('users').doc(user.uid);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Earning App'),
        actions: [
          IconButton(
            tooltip: 'Log out',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Your dashboard', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text('Signed in as ${user.email ?? 'user'}'),
                const SizedBox(height: 20),
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: profile.snapshots(),
                  builder: (context, snapshot) {
                    final data = snapshot.data?.data() ?? {};
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Welcome, ${data['displayName'] ?? 'member'}',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            const Text('Account status: Active'),
                            const SizedBox(height: 8),
                            SelectableText('Referral code: ${data['referralCode'] ?? 'Loading...'}'),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.task_alt),
                    title: Text('Sponsored tasks'),
                    subtitle: Text('Tasks will appear here after the admin system is added.'),
                  ),
                ),
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.groups_outlined),
                    title: Text('Invite your team'),
                    subtitle: Text('Referral tracking is planned; rewards will require server-side validation.'),
                  ),
                ),
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.account_balance_wallet_outlined),
                    title: Text('Wallet'),
                    subtitle: Text('Wallet and withdrawal features are not enabled in this starter build.'),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Rewards are subject to verified task rules and available sponsor funding. No earnings are guaranteed.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
