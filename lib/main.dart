import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const QuizPage(),
    );
  }
}

class ScienceQuestion {
  final String text;
  final String correctAnswer;

  const ScienceQuestion({
    required this.text,
    required this.correctAnswer,
  });

  factory ScienceQuestion.fromJson(Map<String, dynamic> json) {
    final question = json['question'];
    final correctAnswer = json['correct_answer'];

    if (question is! String || correctAnswer is! String) {
      throw const FormatException('Invalid question data.');
    }

    final decodedQuestion = Uri.decodeComponent(question);
    final decodedAnswer = Uri.decodeComponent(correctAnswer);

    if (decodedAnswer != 'True' && decodedAnswer != 'False') {
      throw const FormatException('Invalid answer data.');
    }

    return ScienceQuestion(
      text: decodedQuestion,
      correctAnswer: decodedAnswer,
    );
  }
}

class QuizPage extends StatefulWidget {
  const QuizPage({super.key});

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  List<ScienceQuestion> _questions = [];
  List<String?> _selectedAnswers = [];

  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _submissionComplete = false;

  String? _errorMessage;
  String? _currentSelection;

  int _currentIndex = 0;
  int _score = 0;

  @override
  void initState() {
    super.initState();
    _fetchQuestions();
  }

  Future<void> _fetchQuestions() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _questions = [];
      _selectedAnswers = [];
      _currentIndex = 0;
      _score = 0;
      _currentSelection = null;
      _submissionComplete = false;
    });

    try {
      final uri = Uri.https(
        'opentdb.com',
        '/api.php',
        {
          'amount': '5',
          'category': '17',
          'difficulty': 'medium',
          'type': 'boolean',
          'encode': 'url3986',
        },
      );

      final response = await http.get(uri);

      if (response.statusCode != 200) {
        throw Exception(
          'Request failed with HTTP status ${response.statusCode}.',
        );
      }

      final data = jsonDecode(response.body);

      if (data is! Map<String, dynamic>) {
        throw const FormatException('Invalid API response.');
      }

      if (data['response_code'] != 0) {
        throw Exception(
          'Trivia API returned response code ${data['response_code']}.',
        );
      }

      final results = data['results'];

      if (results is! List || results.length != 5) {
        throw const FormatException(
          'The API did not return exactly five questions.',
        );
      }

      final questions = results
          .map(
            (item) => ScienceQuestion.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();

      if (!mounted) return;

      setState(() {
        _questions = questions;
        _selectedAnswers = List<String?>.filled(questions.length, null);
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _errorMessage = 'Could not load the quiz.\n$error';
      });
    }
  }

  void _selectAnswer(String answer) {
    if (_currentSelection != null) {
      return;
    }

    final question = _questions[_currentIndex];
    final isCorrect = answer == question.correctAnswer;

    setState(() {
      _currentSelection = answer;
      _selectedAnswers[_currentIndex] = answer;

      if (isCorrect) {
        _score++;
      }
    });
  }

  void _continueQuiz() {
    if (_currentSelection == null) {
      return;
    }

    if (_currentIndex < _questions.length - 1) {
      setState(() {
        _currentIndex++;
        _currentSelection = null;
      });
    } else {
      setState(() {
        _currentIndex = _questions.length;
        _currentSelection = null;
      });
    }
  }

  Future<void> _simulateSubmission() async {
    if (_isSubmitting || _submissionComplete) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    await Future<void>.delayed(const Duration(seconds: 1));

    if (!mounted) return;

    setState(() {
      _isSubmitting = false;
      _submissionComplete = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Science Signal'),
        centerTitle: true,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
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

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 60,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _fetchQuestions,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_currentIndex >= _questions.length) {
      return _buildResults();
    }

    return _buildQuestion();
  }

  Widget _buildQuestion() {
    final question = _questions[_currentIndex];
    final answered = _currentSelection != null;
    final isCorrect = _currentSelection == question.correctAnswer;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Question ${_currentIndex + 1} of ${_questions.length}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: (_currentIndex + 1) / _questions.length,
          ),
          const SizedBox(height: 32),
          Text(
            question.text,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: answered ? null : () => _selectAnswer('True'),
            child: const Text('True'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: answered ? null : () => _selectAnswer('False'),
            child: const Text('False'),
          ),
          if (answered) ...[
            const SizedBox(height: 28),
            Text(
              isCorrect
                  ? 'Correct!'
                  : 'Incorrect. Correct answer: ${question.correctAnswer}',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isCorrect ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _continueQuiz,
              child: Text(
                _currentIndex == _questions.length - 1
                    ? 'View Results'
                    : 'Continue',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResults() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Quiz Complete',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Score: $_score / ${_questions.length}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 24),
        const Text(
          'Answer Review',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ...List.generate(_questions.length, (index) {
          final question = _questions[index];
          final selected = _selectedAnswers[index];
          final correct = selected == question.correctAnswer;

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
                  Text('Your answer: ${selected ?? "No answer"}'),
                  Text('Correct answer: ${question.correctAnswer}'),
                  const SizedBox(height: 4),
                  Text(
                    correct ? 'Correct' : 'Incorrect',
                    style: TextStyle(
                      color: correct ? Colors.green : Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _isSubmitting || _submissionComplete
              ? null
              : _simulateSubmission,
          child: Text(
            _isSubmitting
                ? 'Simulating submission...'
                : _submissionComplete
                    ? 'Simulation Complete'
                    : 'Simulate Score Submission',
          ),
        ),
        if (_submissionComplete) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Simulation only. No backend request was sent.\n\n'
                'Payload:\n'
                '{\n'
                '  "score": $_score,\n'
                '  "total": ${_questions.length},\n'
                '  "category": "Science & Nature"\n'
                '}',
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _fetchQuestions,
          child: const Text('Replay with New Questions'),
        ),
      ],
    );
  }
}