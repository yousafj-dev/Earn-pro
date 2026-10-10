import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'firebase_options.dart';

// ---------------------------------------------------------------------------
// App constants
// ---------------------------------------------------------------------------

/// Primary brand color for the earning theme.
const Color kPrimaryGreen = Color(0xFF16A34A);

/// Points awarded for each daily check-in.
const int kCheckInReward = 10;

/// Bonus points awarded to BOTH the referrer and the new user.
const int kReferralBonus = 50;

/// Minimum withdrawal amount in PKR.
const int kMinWithdraw = 100;

/// Supported withdrawal methods.
const List<String> kWithdrawMethods = <String>[
  'Easypaisa',
  'JazzCash',
  'Bank Transfer',
];

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const EarnProApp());
}

class EarnProApp extends StatelessWidget {
  const EarnProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EarnPro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: kPrimaryGreen),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Returns today's date as 'yyyy-MM-dd' in local time.
String todayKey() {
  final now = DateTime.now();
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return '${now.year}-$m-$d';
}

/// Formats a Firestore Timestamp (or DateTime) for display.
String formatDateTime(dynamic value) {
  DateTime? dt;
  if (value is Timestamp) dt = value.toDate();
  if (value is DateTime) dt = value;
  if (dt == null) return 'Just now';
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inDays < 1) return '${diff.inHours} h ago';
  if (diff.inDays < 7) return '${diff.inDays} d ago';
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

/// Friendly message for FirebaseAuthException codes.
String authErrorMessage(String code) {
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
    case 'too-many-requests':
      return 'Too many attempts. Please try again later.';
    default:
      return 'Could not authenticate ($code). Please try again.';
  }
}

/// Friendly message for Firestore / general errors.
String friendlyError(Object e) {
  if (e is FirebaseException) {
    switch (e.code) {
      case 'permission-denied':
        return 'Permission denied. Please check Firestore security rules.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'Network error. Check your internet connection and try again.';
      case 'not-found':
        return 'Requested data was not found.';
      default:
        return 'Something went wrong (${e.code}). Please try again.';
    }
  }
  final msg = e.toString().replaceFirst('Exception: ', '');
  return msg.length > 140 ? '${msg.substring(0, 140)}...' : msg;
}

// ---------------------------------------------------------------------------
// Firestore service — all database operations in one place
// ---------------------------------------------------------------------------

class EarnProService {
  EarnProService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');
  static CollectionReference<Map<String, dynamic>> get _tasks =>
      _db.collection('tasks');
  static CollectionReference<Map<String, dynamic>> get _transactions =>
      _db.collection('transactions');
  static CollectionReference<Map<String, dynamic>> get _withdrawals =>
      _db.collection('withdrawals');

  /// Stream of the signed-in user's profile document.
  static Stream<DocumentSnapshot<Map<String, dynamic>>> userStream(String uid) {
    return _users.doc(uid).snapshots();
  }

  /// Creates the default profile document for a user (idempotent).
  static Future<void> ensureUserDoc({
    required String uid,
    required String email,
    required String displayName,
  }) async {
    final ref = _users.doc(uid);
    final snap = await ref.get();
    if (snap.exists) return;
    final code = await generateUniqueReferralCode();
    await ref.set({
      'uid': uid,
      'displayName': displayName,
      'email': email,
      'balance': 0,
      'points': 0,
      'totalEarnings': 0,
      'referralCode': code,
      'referredBy': '',
      'lastCheckIn': '',
      'accountStatus': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Generates a referral code that does not collide with an existing one.
  static Future<String> generateUniqueReferralCode() async {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    for (var i = 0; i < 10; i++) {
      final code =
          List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
      final q = await _users
          .where('referralCode', isEqualTo: code)
          .limit(1)
          .get();
      if (q.docs.isEmpty) return code;
    }
    // Extremely unlikely fallback.
    return 'EP${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';
  }

  /// Finds a user id by referral code, or null when the code is invalid.
  static Future<String?> findUidByReferralCode(String code) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) return null;
    final q = await _users
        .where('referralCode', isEqualTo: normalized)
        .limit(1)
        .get();
    if (q.docs.isEmpty) return null;
    return q.docs.first.id;
  }

  /// Awards points to a user and records a transaction, atomically.
  static Future<void> awardPoints({
    required String uid,
    required int points,
    required String type,
    required String description,
  }) async {
    final userRef = _users.doc(uid);
    final txRef = _transactions.doc();
    await _db.runTransaction((t) async {
      final snap = await t.get(userRef);
      if (!snap.exists) throw Exception('User profile not found.');
      final data = snap.data()!;
      final curPoints = (data['points'] ?? 0) as int;
      final curTotal = (data['totalEarnings'] ?? 0) as int;
      final next = curPoints + points;
      t.update(userRef, {
        'points': next,
        'balance': next, // 1 point = Rs 1
        'totalEarnings': curTotal + points,
      });
      t.set(txRef, {
        'userId': uid,
        'type': type,
        'amount': points,
        'description': description,
        'timestamp': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Claims the daily check-in reward. Returns true when points were awarded,
  /// false when the user already claimed today.
  static Future<bool> claimDailyCheckIn(String uid) async {
    final today = todayKey();
    final userRef = _users.doc(uid);
    var alreadyClaimed = false;
    await _db.runTransaction((t) async {
      final snap = await t.get(userRef);
      if (!snap.exists) throw Exception('User profile not found.');
      final data = snap.data()!;
      if ((data['lastCheckIn'] ?? '') == today) {
        alreadyClaimed = true;
        return;
      }
      final curPoints = (data['points'] ?? 0) as int;
      final curTotal = (data['totalEarnings'] ?? 0) as int;
      final next = curPoints + kCheckInReward;
      t.update(userRef, {
        'points': next,
        'balance': next,
        'totalEarnings': curTotal + kCheckInReward,
        'lastCheckIn': today,
      });
      t.set(_transactions.doc(), {
        'userId': uid,
        'type': 'checkin',
        'amount': kCheckInReward,
        'description': 'Daily check-in reward',
        'timestamp': FieldValue.serverTimestamp(),
      });
    });
    return !alreadyClaimed;
  }

  /// Marks a task complete and awards its reward, atomically.
  static Future<void> completeTask({
    required String uid,
    required String taskId,
    required int reward,
    required String taskTitle,
  }) async {
    final userRef = _users.doc(uid);
    final doneRef = userRef.collection('completedTasks').doc(taskId);
    await _db.runTransaction((t) async {
      final doneSnap = await t.get(doneRef);
      if (doneSnap.exists) throw Exception('Task already completed.');
      final userSnap = await t.get(userRef);
      if (!userSnap.exists) throw Exception('User profile not found.');
      final data = userSnap.data()!;
      final curPoints = (data['points'] ?? 0) as int;
      final curTotal = (data['totalEarnings'] ?? 0) as int;
      final next = curPoints + reward;
      t.set(doneRef, {
        'taskId': taskId,
        'reward': reward,
        'completedAt': FieldValue.serverTimestamp(),
      });
      t.update(userRef, {
        'points': next,
        'balance': next,
        'totalEarnings': curTotal + reward,
      });
      t.set(_transactions.doc(), {
        'userId': uid,
        'type': 'task',
        'amount': reward,
        'description': 'Completed task: $taskTitle',
        'timestamp': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Applies a referral code for [newUid]. Awards the bonus to both users.
  static Future<void> applyReferral({
    required String newUid,
    required String code,
  }) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) throw Exception('Please enter a referral code.');
    final referrerUid = await findUidByReferralCode(normalized);
    if (referrerUid == null) throw Exception('Invalid referral code.');
    if (referrerUid == newUid) {
      throw Exception('You cannot use your own referral code.');
    }

    final newRef = _users.doc(newUid);
    final refRef = _users.doc(referrerUid);

    await _db.runTransaction((t) async {
      final newSnap = await t.get(newRef);
      if (!newSnap.exists) throw Exception('User profile not found.');
      final newData = newSnap.data()!;
      if ((newData['referredBy'] ?? '').toString().isNotEmpty) {
        throw Exception('A referral code was already applied.');
      }
      final refSnap = await t.get(refRef);
      if (!refSnap.exists) throw Exception('Referrer not found.');
      final refData = refSnap.data()!;

      // New user side.
      final newPoints = ((newData['points'] ?? 0) as int) + kReferralBonus;
      final newTotal =
          ((newData['totalEarnings'] ?? 0) as int) + kReferralBonus;
      t.update(newRef, {
        'points': newPoints,
        'balance': newPoints,
        'totalEarnings': newTotal,
        'referredBy': normalized,
      });
      t.set(_transactions.doc(), {
        'userId': newUid,
        'type': 'referral',
        'amount': kReferralBonus,
        'description': 'Referral signup bonus',
        'timestamp': FieldValue.serverTimestamp(),
      });

      // Referrer side.
      final refPoints = ((refData['points'] ?? 0) as int) + kReferralBonus;
      final refTotal =
          ((refData['totalEarnings'] ?? 0) as int) + kReferralBonus;
      t.update(refRef, {
        'points': refPoints,
        'balance': refPoints,
        'totalEarnings': refTotal,
      });
      t.set(_transactions.doc(), {
        'userId': referrerUid,
        'type': 'referral',
        'amount': kReferralBonus,
        'description': 'Referral reward — a friend joined',
        'timestamp': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Submits a withdrawal request with status "pending".
  static Future<void> submitWithdrawal({
    required String uid,
    required int amount,
    required String method,
    required String accountNumber,
  }) async {
    if (amount < kMinWithdraw) {
      throw Exception('Minimum withdrawal is Rs $kMinWithdraw.');
    }
    if (accountNumber.trim().isEmpty) {
      throw Exception('Please enter your account number.');
    }
    final snap = await _users.doc(uid).get();
    if (!snap.exists) throw Exception('User profile not found.');
    final balance = ((snap.data()?['balance'] ?? 0) as int);
    if (amount > balance) {
      throw Exception('Amount is more than your available balance (Rs $balance).');
    }
    await _withdrawals.add({
      'userId': uid,
      'amount': amount,
      'method': method,
      'accountNumber': accountNumber.trim(),
      'status': 'pending',
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  /// Stream of active sponsored tasks.
  static Stream<QuerySnapshot<Map<String, dynamic>>> activeTasksStream() {
    return _tasks.where('active', isEqualTo: true).snapshots();
  }

  /// Stream of the task ids the user has already completed.
  static Stream<Set<String>> completedTaskIdsStream(String uid) {
    return _users
        .doc(uid)
        .collection('completedTasks')
        .snapshots()
        .map((s) => s.docs.map((d) => d.id).toSet());
  }

  /// Stream of the user's transactions (newest first, sorted client-side to
  /// avoid requiring a composite Firestore index).
  static Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      transactionsStream(String uid) {
    return _transactions
        .where('userId', isEqualTo: uid)
        .snapshots()
        .map((s) {
      final docs = s.docs.toList();
      docs.sort((a, b) {
        final ta = a.data()['timestamp'];
        final tb = b.data()['timestamp'];
        final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        final db2 = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        return db2.compareTo(da);
      });
      return docs;
    });
  }

  /// Stream of the user's withdrawal requests (newest first).
  static Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      withdrawalsStream(String uid) {
    return _withdrawals
        .where('userId', isEqualTo: uid)
        .snapshots()
        .map((s) {
      final docs = s.docs.toList();
      docs.sort((a, b) {
        final ta = a.data()['timestamp'];
        final tb = b.data()['timestamp'];
        final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        final db2 = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        return db2.compareTo(da);
      });
      return docs;
    });
  }

  /// How many users joined with this referral code.
  static Future<int> referralCount(String code) async {
    if (code.isEmpty) return 0;
    final q = await _users
        .where('referredBy', isEqualTo: code)
        .limit(100)
        .get();
    return q.docs.length;
  }
}

// ---------------------------------------------------------------------------
// Auth gate — routes to login or home based on Firebase Auth state
// ---------------------------------------------------------------------------

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == null) return const AuthPage();
        return const HomeShell();
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Sign up / Login page (with optional referral code on signup)
// ---------------------------------------------------------------------------

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _referral = TextEditingController();
  bool _isSignup = true;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _referral.dispose();
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
        await EarnProService.ensureUserDoc(
          uid: user.uid,
          email: user.email ?? _email.text.trim(),
          displayName: _name.text.trim(),
        );
        final code = _referral.text.trim();
        if (code.isNotEmpty) {
          try {
            await EarnProService.applyReferral(newUid: user.uid, code: code);
          } catch (e) {
            // Signup succeeded; only the referral bonus failed.
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Signed up, but referral failed: ${friendlyError(e)}'),
                ),
              );
            }
          }
        }
      } else {
        await auth.signInWithEmailAndPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = authErrorMessage(e.code));
    } catch (e) {
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: kPrimaryGreen.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 44,
                    color: kPrimaryGreen,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'EarnPro',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: kPrimaryGreen,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isSignup
                      ? 'Create your account and start earning'
                      : 'Welcome back to EarnPro',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                Card(
                  elevation: 0,
                  color: cs.surfaceContainerHighest.withOpacity(0.4),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_isSignup) ...[
                            TextFormField(
                              controller: _name,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(
                                labelText: 'Full name',
                                prefixIcon: Icon(Icons.person_outline),
                                border: OutlineInputBorder(),
                              ),
                              validator: (v) =>
                                  (v == null || v.trim().length < 2)
                                      ? 'Enter your name'
                                      : null,
                            ),
                            const SizedBox(height: 14),
                          ],
                          TextFormField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.email_outlined),
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                (v == null || !v.contains('@'))
                                    ? 'Enter a valid email'
                                    : null,
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: _password,
                            obscureText: _obscure,
                            autofillHints: _isSignup
                                ? const [AutofillHints.newPassword]
                                : const [AutofillHints.password],
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline),
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                icon: Icon(_obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                            validator: (v) => (v == null || v.length < 6)
                                ? 'Use at least 6 characters'
                                : null,
                          ),
                          if (_isSignup) ...[
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _referral,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                labelText: 'Referral code (optional)',
                                hintText: 'Enter a friend\'s code for bonus',
                                prefixIcon: Icon(Icons.card_giftcard_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              style: TextStyle(color: cs.error),
                            ),
                          ],
                          const SizedBox(height: 18),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: kPrimaryGreen,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    _isSignup ? 'Sign up' : 'Log in',
                                    style: const TextStyle(fontSize: 16),
                                  ),
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
                const SizedBox(height: 12),
                const Text(
                  'Complete tasks, check in daily and invite friends to earn rewards.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home shell with bottom navigation
// ---------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _ensureProfile();
  }

  Future<void> _ensureProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await EarnProService.ensureUserDoc(
        uid: user.uid,
        email: user.email ?? '',
        displayName: user.displayName ?? 'Member',
      );
    } catch (_) {
      // Non-fatal: the dashboard will surface load errors if needed.
    }
  }

  void _goTo(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const AuthPage();
    final uid = user.uid;

    final pages = <Widget>[
      DashboardTab(uid: uid, onGoToTasks: () => _goTo(1)),
      TasksTab(uid: uid),
      WalletTab(uid: uid),
      ReferralTab(uid: uid),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'EarnPro',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: kPrimaryGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goTo,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.task_alt_outlined),
            selectedIcon: Icon(Icons.task_alt),
            label: 'Tasks',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: 'Wallet',
          ),
          NavigationDestination(
            icon: Icon(Icons.group_add_outlined),
            selectedIcon: Icon(Icons.group_add),
            label: 'Referral',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard tab — stats, daily check-in, quick actions
// ---------------------------------------------------------------------------

class DashboardTab extends StatelessWidget {
  final String uid;
  final VoidCallback onGoToTasks;

  const DashboardTab({
    super.key,
    required this.uid,
    required this.onGoToTasks,
  });

  Future<void> _claimCheckIn(BuildContext context) async {
    try {
      final claimed = await EarnProService.claimDailyCheckIn(uid);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            claimed
                ? 'Check-in successful! +$kCheckInReward points added.'
                : 'You already claimed today. Come back tomorrow!',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: EarnProService.userStream(uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _ErrorView(
            message: friendlyError(snapshot.error!),
            onRetry: () => (context as Element).markNeedsBuild(),
          );
        }
        final data = snapshot.data?.data();
        if (data == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Setting up your profile... please wait a moment.'),
            ),
          );
        }

        final balance = (data['balance'] ?? 0) as int;
        final points = (data['points'] ?? 0) as int;
        final total = (data['totalEarnings'] ?? 0) as int;
        final name = (data['displayName'] ?? 'Member').toString();
        final claimedToday = (data['lastCheckIn'] ?? '') == todayKey();

        return RefreshIndicator(
          onRefresh: () async {},
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Hello, $name 👋',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text('Here is your earning summary.'),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: StatCard(
                        icon: Icons.account_balance_wallet,
                        label: 'Balance',
                        value: 'Rs $balance',
                        color: kPrimaryGreen,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StatCard(
                        icon: Icons.stars,
                        label: 'Points',
                        value: '$points',
                        color: Colors.amber.shade700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                StatCard(
                  icon: Icons.trending_up,
                  label: 'Total Earnings (all time)',
                  value: '$total pts',
                  color: Colors.blue.shade700,
                ),
                const SizedBox(height: 16),
                // Daily check-in card.
                Card(
                  elevation: 0,
                  color: kPrimaryGreen.withOpacity(0.08),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: kPrimaryGreen.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.calendar_month_outlined,
                            color: kPrimaryGreen,
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Daily Check-in',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              Text(
                                claimedToday
                                    ? 'Claimed for today. Come back tomorrow!'
                                    : 'Claim +$kCheckInReward points now',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: claimedToday
                                ? Colors.grey
                                : kPrimaryGreen,
                          ),
                          onPressed: claimedToday
                              ? null
                              : () => _claimCheckIn(context),
                          child: Text(claimedToday ? 'Claimed ✓' : 'Claim'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Quick actions',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.task_alt_outlined,
                        label: 'Earn Tasks',
                        onTap: onGoToTasks,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.payments_outlined,
                        label: 'Withdraw',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => WithdrawPage(
                                uid: uid,
                                balance: balance,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Rewards depend on verified tasks and available sponsor funding. No earnings are guaranteed.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Icon(icon, color: kPrimaryGreen, size: 30),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tasks tab — sponsored tasks from Firestore
// ---------------------------------------------------------------------------

class TasksTab extends StatelessWidget {
  final String uid;

  const TasksTab({super.key, required this.uid});

  Future<void> _completeTask(
    BuildContext context,
    String taskId,
    int reward,
    String title,
  ) async {
    try {
      await EarnProService.completeTask(
        uid: uid,
        taskId: taskId,
        reward: reward,
        taskTitle: title,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Task completed! +$reward points added.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: EarnProService.activeTasksStream(),
      builder: (context, taskSnap) {
        if (taskSnap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (taskSnap.hasError) {
          return _ErrorView(message: friendlyError(taskSnap.error!));
        }
        final tasks = taskSnap.data?.docs ?? [];

        return StreamBuilder<Set<String>>(
          stream: EarnProService.completedTaskIdsStream(uid),
          builder: (context, doneSnap) {
            final done = doneSnap.data ?? <String>{};
            if (tasks.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.task_alt_outlined,
                          size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text(
                        'No tasks right now',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'New sponsored tasks will appear here. Check back soon!',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: tasks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final doc = tasks[i];
                final data = doc.data();
                final title = (data['title'] ?? 'Untitled task').toString();
                final desc = (data['description'] ?? '').toString();
                final reward = (data['reward'] ?? 0) as int;
                final isDone = done.contains(doc.id);
                return Card(
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: kPrimaryGreen.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '+$reward pts',
                                style: const TextStyle(
                                  color: kPrimaryGreen,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (desc.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(desc),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: isDone
                              ? OutlinedButton.icon(
                                  onPressed: null,
                                  icon: Icon(Icons.check_circle_outline),
                                  label: Text('Completed'),
                                )
                              : FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: kPrimaryGreen,
                                  ),
                                  onPressed: () => _completeTask(
                                      context, doc.id, reward, title),
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('Complete Task'),
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Wallet tab — balance, pending withdrawals, transaction history
// ---------------------------------------------------------------------------

class WalletTab extends StatelessWidget {
  final String uid;

  const WalletTab({super.key, required this.uid});

  IconData _iconForType(String type) {
    switch (type) {
      case 'checkin':
        return Icons.calendar_month_outlined;
      case 'task':
        return Icons.task_alt_outlined;
      case 'referral':
        return Icons.group_add_outlined;
      case 'withdrawal':
        return Icons.payments_outlined;
      default:
        return Icons.stars_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: EarnProService.userStream(uid),
      builder: (context, userSnap) {
        final data = userSnap.data?.data();
        final balance = ((data?['balance'] ?? 0) as int);

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 0,
                color: kPrimaryGreen,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Wallet Balance',
                        style: TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Rs $balance',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: kPrimaryGreen,
                        ),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => WithdrawPage(
                                uid: uid,
                                balance: balance,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.payments_outlined),
                        label: const Text('Withdraw'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Pending withdrawals',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                stream: EarnProService.withdrawalsStream(uid),
                builder: (context, wSnap) {
                  if (wSnap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  }
                  final pending = (wSnap.data ?? [])
                      .where((d) =>
                          (d.data()['status'] ?? '') == 'pending')
                      .toList();
                  if (pending.isEmpty) {
                    return const Card(
                      elevation: 0,
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No pending withdrawal requests.'),
                      ),
                    );
                  }
                  return Column(
                    children: pending.map((d) {
                      final w = d.data();
                      return Card(
                        elevation: 0,
                        child: ListTile(
                          leading: const Icon(Icons.hourglass_top_outlined,
                              color: Colors.orange),
                          title: Text(
                              'Rs ${w['amount']} via ${w['method']}'),
                          subtitle: Text(
                              'Status: pending • ${formatDateTime(w['timestamp'])}'),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                'Transaction history',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                stream: EarnProService.transactionsStream(uid),
                builder: (context, tSnap) {
                  if (tSnap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (tSnap.hasError) {
                    return _ErrorView(
                        message: friendlyError(tSnap.error!));
                  }
                  final txs = tSnap.data ?? [];
                  if (txs.isEmpty) {
                    return const Card(
                      elevation: 0,
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(Icons.receipt_long_outlined,
                                size: 48, color: Colors.grey),
                            SizedBox(height: 8),
                            Text(
                                'No transactions yet. Complete tasks or check in daily to earn!'),
                          ],
                        ),
                      ),
                    );
                  }
                  return Column(
                    children: txs.map((d) {
                      final t = d.data();
                      final type = (t['type'] ?? '').toString();
                      final amount = (t['amount'] ?? 0) as int;
                      final desc =
                          (t['description'] ?? type).toString();
                      return Card(
                        elevation: 0,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                kPrimaryGreen.withOpacity(0.12),
                            child: Icon(
                              _iconForType(type),
                              color: kPrimaryGreen,
                            ),
                          ),
                          title: Text(desc),
                          subtitle:
                              Text(formatDateTime(t['timestamp'])),
                          trailing: Text(
                            '+$amount',
                            style: const TextStyle(
                              color: kPrimaryGreen,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Referral tab — show code, copy, apply a friend's code
// ---------------------------------------------------------------------------

class ReferralTab extends StatefulWidget {
  final String uid;

  const ReferralTab({super.key, required this.uid});

  @override
  State<ReferralTab> createState() => _ReferralTabState();
}

class _ReferralTabState extends State<ReferralTab> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Referral code copied!')),
    );
  }

  Future<void> _applyCode() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a referral code.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await EarnProService.applyReferral(newUid: widget.uid, code: code);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Referral applied! +$kReferralBonus points for you and your friend.'),
        ),
      );
      _code.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: EarnProService.userStream(widget.uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _ErrorView(message: friendlyError(snapshot.error!));
        }
        final data = snapshot.data?.data() ?? {};
        final code = (data['referralCode'] ?? '').toString();
        final referredBy = (data['referredBy'] ?? '').toString();

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 0,
                color: kPrimaryGreen.withOpacity(0.08),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.card_giftcard,
                        size: 48,
                        color: kPrimaryGreen,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Your referral code',
                        style: TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        code.isEmpty ? '...' : code,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                          color: kPrimaryGreen,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: kPrimaryGreen,
                        ),
                        onPressed: code.isEmpty
                            ? null
                            : () => _copyCode(code),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('Copy code'),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Share it with friends — you both get +$kReferralBonus points when they join.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FutureBuilder<int>(
                future: EarnProService.referralCount(code),
                builder: (context, cSnap) {
                  final count = cSnap.data ?? 0;
                  return Row(
                    children: [
                      Expanded(
                        child: StatCard(
                          icon: Icons.group_outlined,
                          label: 'Friends joined',
                          value: '$count',
                          color: Colors.blue.shade700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: StatCard(
                          icon: Icons.stars_outlined,
                          label: 'Referral earnings',
                          value: '${count * kReferralBonus}',
                          color: Colors.amber.shade700,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              if (referredBy.isEmpty) ...[
                Text(
                  'Have a friend\'s code?',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Card(
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _code,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: 'Referral code',
                            hintText: 'e.g. X7K2P9QW',
                            prefixIcon:
                                Icon(Icons.confirmation_number_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: kPrimaryGreen,
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _busy ? null : _applyCode,
                          child: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Apply code'),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                Card(
                  elevation: 0,
                  child: ListTile(
                    leading: const Icon(Icons.check_circle,
                        color: kPrimaryGreen),
                    title: const Text('Referral applied'),
                    subtitle: Text('You joined with code: $referredBy'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Withdraw page — submit a withdrawal request
// ---------------------------------------------------------------------------

class WithdrawPage extends StatefulWidget {
  final String uid;
  final int balance;

  const WithdrawPage({super.key, required this.uid, required this.balance});

  @override
  State<WithdrawPage> createState() => _WithdrawPageState();
}

class _WithdrawPageState extends State<WithdrawPage> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _account = TextEditingController();
  String? _method;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _account.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_method == null) {
      setState(() => _error = 'Please select a payment method.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final amount = int.parse(_amount.text.trim());
      await EarnProService.submitWithdrawal(
        uid: widget.uid,
        amount: amount,
        method: _method!,
        accountNumber: _account.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Withdrawal request submitted! Status: pending approval.'),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Withdraw'),
        backgroundColor: kPrimaryGreen,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 0,
                color: kPrimaryGreen.withOpacity(0.08),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.account_balance_wallet_outlined,
                          color: kPrimaryGreen, size: 32),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Available balance'),
                          Text(
                            'Rs ${widget.balance}',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: kPrimaryGreen,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _amount,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Amount (Rs)',
                        hintText: 'Minimum Rs $kMinWithdraw',
                        prefixIcon: Icon(Icons.payments_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim());
                        if (n == null || n <= 0) return 'Enter an amount';
                        if (n < kMinWithdraw) {
                          return 'Minimum withdrawal is Rs $kMinWithdraw';
                        }
                        if (n > widget.balance) {
                          return 'Amount is more than your balance';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: _method,
                      decoration: const InputDecoration(
                        labelText: 'Payment method',
                        prefixIcon: Icon(Icons.account_balance_outlined),
                        border: OutlineInputBorder(),
                      ),
                      hint: const Text('Select payment method'),
                      items: kWithdrawMethods
                          .map((m) => DropdownMenuItem(
                                value: m,
                                child: Text(m),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _method = v),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _account,
                      keyboardType: TextInputType.text,
                      decoration: const InputDecoration(
                        labelText: 'Account number',
                        hintText: 'Your Easypaisa / JazzCash / bank number',
                        prefixIcon: Icon(Icons.numbers_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().length < 5)
                              ? 'Enter a valid account number'
                              : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                          style: TextStyle(color: cs.error)),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: kPrimaryGreen,
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Submit withdrawal request',
                              style: TextStyle(fontSize: 16),
                            ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Requests are reviewed by the admin. Status stays "pending" until approved.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

/// A small stat card used on the dashboard and referral screens.
class StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const StatCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Simple centered error view with an optional retry button.
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorView({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
