
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const ScienceSignalApp());
}

class ScienceSignalApp extends StatelessWidget {
  const ScienceSignalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Science Signal',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
        ),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

// SCIENCE QUESTION MODEL

class ScienceQuestion {
  final String text;
  final String correctAnswer;

  const ScienceQuestion({
    required this.text,
    required this.correctAnswer,
  });

  factory ScienceQuestion.fromJson(Map<String, dynamic> json) {
    String decodeField(String key) {
      final value = json[key];

      if (value is! String || value.isEmpty) {
        throw FormatException('Missing or invalid $key');
      }

      final decoded = Uri.decodeComponent(value);

      if (decoded.trim().isEmpty) {
        throw FormatException('Empty $key');
      }

      return decoded;
    }

    final category = decodeField('category');
    final difficulty = decodeField('difficulty');
    final type = decodeField('type');
    final question = decodeField('question');
    final correct = decodeField('correct_answer');

    final incorrectList = json['incorrect_answers'];

    if (category != 'Science & Nature' ||
        difficulty != 'medium' ||
        type != 'boolean' ||
        incorrectList is! List ||
        incorrectList.length != 1 ||
        incorrectList.first is! String) {
      throw const FormatException(
        'Invalid Science and Nature question format.',
      );
    }

    final incorrect = Uri.decodeComponent(
      incorrectList.first as String,
    );

    final validAnswers =
        (correct == 'True' && incorrect == 'False') ||
        (correct == 'False' && incorrect == 'True');

    if (!validAnswers) {
      throw const FormatException(
        'Expected exactly True and False answers.',
      );
    }

    return ScienceQuestion(
      text: question,
      correctAnswer: correct,
    );
  }
}

// FIRESTORE REPOSITORY

class AttemptRepository {
  final FirebaseFirestore firestore =
      FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> reference(
    String uid,
    String roundId,
  ) {
    return firestore
        .collection('users')
        .doc(uid)
        .collection('attempts')
        .doc(roundId);
  }

  String newRoundId(String uid) {
    return firestore
        .collection('users')
        .doc(uid)
        .collection('attempts')
        .doc()
        .id;
  }

  Map<String, dynamic> fixedData(int score) {
    return {
      'schemaVersion': 1,
      'variant': 'B',
      'categoryId': 17,
      'questionCount': 5,
      'correctCount': score,
    };
  }

  bool matches(
    Map<String, dynamic>? data,
    int score,
  ) {
    if (data == null || data.length != 6) {
      return false;
    }

    final expected = fixedData(score);

    for (final entry in expected.entries) {
      if (data[entry.key] != entry.value) {
        return false;
      }
    }

    return data['submittedAt'] is Timestamp;
  }

  Future<void> commitOnce({
    required String uid,
    required String roundId,
    required int score,
  }) async {
    final ref = reference(uid, roundId);

    final payload = {
      ...fixedData(score),
      'submittedAt': FieldValue.serverTimestamp(),
    };

    await firestore.runTransaction<void>((transaction) async {
      final existing = await transaction.get(ref);

      if (!existing.exists) {
        transaction.set(ref, payload);
        return;
      }

      if (!matches(existing.data(), score)) {
        throw StateError(
          'Collision: this round ID already contains '
          'a different or invalid attempt.',
        );
      }

      // Matching attempt exists.
      // Do not create a second document or update it.
    });
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> verify({
    required String uid,
    required String roundId,
    required int score,
  }) async {
    final snapshot = await reference(
      uid,
      roundId,
    ).get(
      const GetOptions(source: Source.server),
    );

    if (!snapshot.exists ||
        !matches(snapshot.data(), score) ||
        snapshot.metadata.isFromCache ||
        snapshot.metadata.hasPendingWrites) {
      throw StateError(
        'The server record is missing or does not match.',
      );
    }

    return snapshot;
  }

  Future<QuerySnapshot<Map<String, dynamic>>> recentAttempts(
    String uid,
  ) {
    return firestore
        .collection('users')
        .doc(uid)
        .collection('attempts')
        .orderBy('submittedAt', descending: true)
        .limit(5)
        .get(const GetOptions(source: Source.server));
  }
}

// CLOUD STATES

enum SaveState {
  ready,
  submitting,
  verifying,
  cloudVerified,
  verificationUnavailable,
  saveUnknown,
  permissionDenied,
  collision,
}

// QUIZ SCREEN

class QuizPage extends StatefulWidget {
  const QuizPage({super.key});

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  final AttemptRepository repository = AttemptRepository();

  List<ScienceQuestion> questions = [];
  List<String?> answers = [];

  bool loading = true;
  String? requestError;
  String? selectedAnswer;

  int currentIndex = 0;
  int score = 0;

  late final String uid;
  late String roundId;

  int? frozenScore;

  SaveState saveState = SaveState.ready;

  String saveMessage = 'Not submitted yet.';
  String? serverMessage;

  bool transactionRunning = false;
  bool verificationRunning = false;

  bool injectVerificationFailure = false;
  bool injectionUsed = false;

  DateTime? lastApiRequest;
  int requestGeneration = 0;

  bool get sameUser =>
      FirebaseAuth.instance.currentUser?.uid == uid;

  bool get unresolved =>
      transactionRunning ||
      verificationRunning ||
      saveState == SaveState.submitting ||
      saveState == SaveState.verifying ||
      saveState == SaveState.saveUnknown ||
      saveState == SaveState.verificationUnavailable ||
      saveState == SaveState.permissionDenied;

  @override
  void initState() {
    super.initState();

    uid = FirebaseAuth.instance.currentUser!.uid;
    roundId = repository.newRoundId(uid);

    unawaited(fetchQuestions());
  }

  // LOAD QUESTIONS

  Future<void> fetchQuestions() async {
    if (unresolved || !sameUser) return;

    final now = DateTime.now();

    if (lastApiRequest != null &&
        now.difference(lastApiRequest!) <
            const Duration(seconds: 5)) {
      setState(() {
        loading = false;
        requestError =
            'Please wait five seconds before retrying.';
      });
      return;
    }

    lastApiRequest = now;
    final generation = ++requestGeneration;

    setState(() {
      loading = true;
      requestError = null;
      questions = [];
      answers = [];
      currentIndex = 0;
      score = 0;
      selectedAnswer = null;
      frozenScore = null;

      saveState = SaveState.ready;
      saveMessage = 'Not submitted yet.';
      serverMessage = null;
      injectionUsed = false;
    });

    try {
      final url = Uri.https('opentdb.com', '/api.php', {
        'amount': '5',
        'category': '17',
        'difficulty': 'medium',
        'type': 'boolean',
        'encode': 'url3986',
      });

      final response = await http.get(url).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) {
        throw FormatException(
          'HTTP error: ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Invalid JSON response.',
        );
      }

      if (decoded['response_code'] != 0) {
        throw FormatException(
          'API response code: ${decoded['response_code']}',
        );
      }

      final results = decoded['results'];

      if (results is! List || results.length != 5) {
        throw const FormatException(
          'The API must return exactly five questions.',
        );
      }

      final loadedQuestions = results.map((item) {
        if (item is! Map) {
          throw const FormatException(
            'Invalid question record.',
          );
        }

        return ScienceQuestion.fromJson(
          Map<String, dynamic>.from(item),
        );
      }).toList();

      if (!mounted ||
          !sameUser ||
          generation != requestGeneration) {
        return;
      }

      setState(() {
        questions = loadedQuestions;
        answers = List<String?>.filled(5, null);
        loading = false;
      });
    } catch (error) {
      if (!mounted ||
          !sameUser ||
          generation != requestGeneration) {
        return;
      }

      setState(() {
        loading = false;
        requestError = 'Could not load the quiz.\n$error';
      });
    }
  }

  // ANSWER HANDLING

  void chooseAnswer(String answer) {
    if (!sameUser ||
        selectedAnswer != null ||
        currentIndex >= questions.length) {
      return;
    }

    setState(() {
      selectedAnswer = answer;
      answers[currentIndex] = answer;

      if (answer == questions[currentIndex].correctAnswer) {
        score++;
      }
    });
  }

  void continueQuiz() {
    if (selectedAnswer == null) return;

    setState(() {
      currentIndex++;
      selectedAnswer = null;
    });
  }

  // CLOUD SUBMISSION

  Future<void> submitCloud() async {
    if (!sameUser ||
        saveState != SaveState.ready ||
        transactionRunning ||
        currentIndex != 5 ||
        questions.length != 5) {
      return;
    }

    frozenScore = score;
    transactionRunning = true;

    setState(() {
      saveState = SaveState.submitting;
      saveMessage = 'Saving your score to Firestore...';
    });

    final commit = repository.commitOnce(
      uid: uid,
      roundId: roundId,
      score: frozenScore!,
    );

    try {
      await commit.timeout(const Duration(seconds: 10));

      transactionRunning = false;

      if (!mounted || !sameUser) return;

      await verifyCloud();
    } on TimeoutException {
      if (!mounted || !sameUser) return;

      setState(() {
        saveState = SaveState.saveUnknown;
        saveMessage =
            'Save outcome unknown. The transaction may '
            'still be running. Keep this round ID.';
      });

      // Observe the original transaction after the UI timeout.
      unawaited(
        commit.then((_) {
          transactionRunning = false;

          if (mounted &&
              sameUser &&
              saveState == SaveState.saveUnknown) {
            setState(() {
              saveMessage =
                  'Transaction finished. Recheck the original round.';
            });
          }
        }).catchError((Object error) {
          transactionRunning = false;

          if (mounted &&
              sameUser &&
              saveState == SaveState.saveUnknown) {
            setState(() {
              saveMessage =
                  'Transaction ended with an error. '
                  'Recheck the same round before trying again.';
            });
          }
        }),
      );
    } on StateError catch (error) {
      transactionRunning = false;

      if (!mounted || !sameUser) return;

      setState(() {
        saveState = SaveState.collision;
        saveMessage = error.message.toString();
      });
    } on FirebaseException catch (error) {
      transactionRunning = false;

      if (!mounted || !sameUser) return;

      setState(() {
        saveState = error.code == 'permission-denied'
            ? SaveState.permissionDenied
            : SaveState.saveUnknown;

        saveMessage =
            'Commit not confirmed (${error.code}). '
            'Recheck the original round.';
      });
    } catch (error) {
      transactionRunning = false;

      if (!mounted || !sameUser) return;

      setState(() {
        saveState = SaveState.saveUnknown;
        saveMessage = 'Commit not confirmed: $error';
      });
    }
  }

  // REAL SERVER VERIFICATION

  Future<void> verifyCloud() async {
    if (!sameUser ||
        transactionRunning ||
        verificationRunning ||
        frozenScore == null) {
      return;
    }

    verificationRunning = true;

    setState(() {
      saveState = SaveState.verifying;
      saveMessage =
          'Checking the saved record on the server...';
    });

    try {
      // Development-only fault injection.
      // The transaction itself is always real.
      if (injectVerificationFailure && !injectionUsed) {
        injectionUsed = true;

        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
          message: 'DEV TEST: verification failure injected',
        );
      }

      final snapshot = await repository.verify(
        uid: uid,
        roundId: roundId,
        score: frozenScore!,
      );

      if (!mounted || !sameUser) return;

      setState(() {
        saveState = SaveState.cloudVerified;

        saveMessage =
            'Cloud verified. This exact attempt exists '
            'on the server.';

        serverMessage =
            'Round ID: ${snapshot.id}\n'
            'Score: ${snapshot.data()!['correctCount']}/5\n'
            'Server timestamp: ${snapshot.data()!['submittedAt']}';
      });
    } on FirebaseException catch (error) {
      if (!mounted || !sameUser) return;

      setState(() {
        saveState = SaveState.verificationUnavailable;

        saveMessage =
            'Write acknowledged; verification unavailable '
            '(${error.code}). Recheck the same round ID.';
      });
    } catch (error) {
      if (!mounted || !sameUser) return;

      setState(() {
        saveState = SaveState.verificationUnavailable;

        saveMessage =
            'Write acknowledged; verification unavailable: $error';
      });
    } finally {
      verificationRunning = false;
    }
  }

  // RETRY SERVER VERIFICATION

  Future<void> recheckOriginalRound() async {
    if (!sameUser ||
        transactionRunning ||
        verificationRunning ||
        frozenScore == null) {
      return;
    }

    // A confirmed commit followed by failed verification
    // only needs another read.
    if (saveState == SaveState.verificationUnavailable) {
      await verifyCloud();
      return;
    }

    verificationRunning = true;

    setState(() {
      saveMessage = 'Rechecking the original round...';
    });

    try {
      final snapshot = await repository.verify(
        uid: uid,
        roundId: roundId,
        score: frozenScore!,
      );

      if (!mounted || !sameUser) return;

      setState(() {
        saveState = SaveState.cloudVerified;
        saveMessage = 'Cloud verified after recovery.';

        serverMessage =
            'Recovered original round: ${snapshot.id}\n'
            'Score: ${snapshot.data()!['correctCount']}/5';
      });
    } on FirebaseException catch (error) {
      if (!mounted || !sameUser) return;

      setState(() {
        saveMessage =
            'Recheck failed (${error.code}). '
            'The original round has not been verified. '
            'Do not create a second attempt.';
      });
    } catch (error) {
      if (!mounted || !sameUser) return;

      setState(() {
        saveMessage =
            'Original round is not verified: $error. '
            'Keep the same round ID.';
      });
    } finally {
      verificationRunning = false;
    }
  }

  // RETRIEVE PREVIOUS ATTEMPT

  Future<void> retrievePreviousAttempt() async {
    if (!sameUser || unresolved) return;

    try {
      final recent = await repository.recentAttempts(uid);

      if (!mounted || !sameUser) return;

      if (recent.docs.isEmpty) {
        setState(() {
          serverMessage = 'No saved attempts found.';
        });
        return;
      }

      final latest = recent.docs.first;
      final savedScore = latest.data()['correctCount'];

      if (savedScore is! int) {
        throw StateError('Invalid stored score.');
      }

      final snapshot = await repository.verify(
        uid: uid,
        roundId: latest.id,
        score: savedScore,
      );

      if (!mounted || !sameUser) return;

      setState(() {
        serverMessage =
            'Retrieved previous attempt from the server.\n'
            'Round ID: ${snapshot.id}\n'
            'Score: $savedScore/5\n'
            'Timestamp: ${snapshot.data()!['submittedAt']}';
      });
    } catch (error) {
      if (!mounted || !sameUser) return;

      setState(() {
        serverMessage = 'Retrieval failed: $error';
      });
    }
  }

  // REPLAY

  Future<void> replay() async {
    if (unresolved || !sameUser) return;

    setState(() {
      roundId = repository.newRoundId(uid);
    });

    await fetchQuestions();
  }

  // MAIN SCREEN

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Science Signal'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: unresolved
                ? null
                : () => FirebaseAuth.instance.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: buildBody(),
    );
  }

  Widget buildBody() {
    if (loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading science questions...'),
          ],
        ),
      );
    }

    if (requestError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 50),
              const SizedBox(height: 16),
              Text(
                requestError!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: fetchQuestions,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (currentIndex >= questions.length) {
      return buildResults();
    }

    return buildQuestion();
  }

  // QUESTION SCREEN

  Widget buildQuestion() {
    final question = questions[currentIndex];

    final answered = selectedAnswer != null;

    final correct =
        selectedAnswer == question.correctAnswer;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Question ${currentIndex + 1} of 5',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: (currentIndex + 1) / 5,
        ),
        const SizedBox(height: 28),
        Text(
          question.text,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: answered
              ? null
              : () => chooseAnswer('True'),
          child: const Text('True'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: answered
              ? null
              : () => chooseAnswer('False'),
          child: const Text('False'),
        ),
        if (answered) ...[
          const SizedBox(height: 24),
          Text(
            correct
                ? 'Correct!'
                : 'Incorrect. Correct answer: '
                    '${question.correctAnswer}',
            style: TextStyle(
              color: correct ? Colors.green : Colors.red,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: continueQuiz,
            child: Text(
              currentIndex == 4
                  ? 'View Results'
                  : 'Continue',
            ),
          ),
        ],
      ],
    );
  }

  // RESULTS SCREEN

  Widget buildResults() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Quiz Complete',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Score: $score / 5',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          'Signed in: '
          '${FirebaseAuth.instance.currentUser?.email ?? ''}',
        ),
        Text(
          'Round ID: $roundId',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 20),
        Text(
          'Answer Review',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        ...List.generate(5, (index) {
          final question = questions[index];
          final correct =
              answers[index] == question.correctAnswer;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${index + 1}. ${question.text}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Your answer: ${answers[index]}'),
                  Text(
                    'Correct answer: '
                    '${question.correctAnswer}',
                  ),
                  Text(
                    correct ? 'Correct' : 'Incorrect',
                    style: TextStyle(
                      color:
                          correct ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: saveState == SaveState.ready
              ? submitCloud
              : null,
          child: Text(
            saveState == SaveState.ready
                ? 'Save Score to Firestore'
                : saveState == SaveState.cloudVerified
                    ? 'Cloud Verified'
                    : 'Cloud Status: ${saveState.name}',
          ),
        ),
        if (saveState == SaveState.ready) ...[
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text(
              'DEV TEST: deny first verification',
            ),
            subtitle: const Text(
              'The real Firestore write still happens. '
              'Only the first verification read is simulated '
              'as denied.',
            ),
            value: injectVerificationFailure,
            onChanged: (value) {
              setState(() {
                injectVerificationFailure = value;
              });
            },
          ),
        ],
        const SizedBox(height: 14),
        Text(saveMessage),
        if (serverMessage != null) ...[
          const SizedBox(height: 12),
          Text(serverMessage!),
        ],
        if ((saveState ==
                    SaveState.verificationUnavailable ||
                saveState == SaveState.saveUnknown ||
                saveState == SaveState.permissionDenied) &&
            !transactionRunning &&
            !verificationRunning)
          OutlinedButton(
            onPressed: recheckOriginalRound,
            child: const Text(
              'Recheck Original Round on Server',
            ),
          ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: unresolved ? null : replay,
          child: const Text(
            'Replay with New Questions',
          ),
        ),
        TextButton(
          onPressed: unresolved
              ? null
              : retrievePreviousAttempt,
          child: const Text(
            'Retrieve Latest Saved Attempt',
          ),
        ),
      ],
    );
  }
}

// AUTHENTICATION GATE

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text(
                'Authentication error: ${snapshot.error}',
              ),
            ),
          );
        }

        if (snapshot.hasData) {
          return const QuizPage();
        }

        return const LoginPage();
      },
    );
  }
}

// LOGIN SCREEN

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool signingIn = false;
  String? loginError;

  Future<void> signIn() async {
    if (signingIn) return;

    setState(() {
      signingIn = true;
      loginError = null;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text,
      );
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;

      setState(() {
        loginError =
            error.message ?? 'Could not sign in.';
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        loginError =
            'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          signingIn = false;
        });
      }
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Science Signal Login'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 100),
          const Text(
            'Sign in to continue',
            style: TextStyle(fontSize: 24),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          if (loginError != null) ...[
            const SizedBox(height: 12),
            Text(
              loginError!,
              style: const TextStyle(color: Colors.red),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: signingIn ? null : signIn,
            child: Text(
              signingIn ? 'Signing in...' : 'Sign In',
            ),
          ),
        ],
      ),
    );
  }
}
