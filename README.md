# Science Signal

**CSC 4360 - Mobile App Development**  
**In-Class Activity \#15 - C2 Science Signal**  
**Student:** Harshit Jain  
**Framework:** Flutter and Dart  
**API:** Open Trivia Database

## Overview

Science Signal is a Flutter true-or-false quiz app that retrieves live
Science & Nature questions from the Open Trivia Database REST API.

The app requests five medium-difficulty questions, converts the API
response into Dart objects, and presents one question at a time. It
handles loading and network errors, prevents repeated scoring, shows
answer feedback, provides a complete results review, supports replay
with fresh questions, and prepares a simulated score submission.

The score submission in this project is intentionally a simulation. No
backend request is sent and no score is saved remotely.

## Features

- Fetches 5 live questions from a REST API
- Uses the Science & Nature category
- Uses medium difficulty and True/False questions
- Decodes URL-encoded question and answer text
- Checks HTTP status and API response code
- Validates that exactly 5 questions were returned
- Shows loading, error, and Retry states
- Displays one question at a time with progress
- Accepts only one answer per question
- Prevents repeated scoring
- Shows correct and incorrect feedback using text and color
- Displays the final score and all 5 review entries
- Simulates a score submission and clearly labels it as a simulation
- Prevents duplicate simulated submissions
- Supports replay with fresh questions

## REST API

The project uses this Open Trivia Database request:

``` text
https://opentdb.com/api.php?amount=5&category=17&difficulty=medium&type=boolean&encode=url3986
```

| Parameter    | Value     | Purpose                   |
|--------------|-----------|---------------------------|
| `amount`     | `5`       | Requests five questions   |
| `category`   | `17`      | Science & Nature          |
| `difficulty` | `medium`  | Medium difficulty         |
| `type`       | `boolean` | True/False questions      |
| `encode`     | `url3986` | URL-encoded returned text |

## Dependency

The project uses the Dart `http` package:

``` yaml
dependencies:
  http: ^1.6.0
```

## Setup and Run

Clone the repository:

``` bash
git clone https://github.com/harshitjain25/science-signal.git
cd science-signal
```

Install dependencies:

``` bash
flutter pub get
```

Check the project:

``` bash
flutter analyze
```

Run on a connected Flutter-supported device:

``` bash
flutter run
```

An internet connection is required to retrieve questions.

## Application Flow

### Loading and API Validation

When the app starts, it requests five questions and displays
`Loading science questions...`.

Before starting the round, the app verifies:

- HTTP status is `200`
- API `response_code` is `0`
- Exactly five results are returned
- Question and answer values are valid
- The correct answer is `True` or `False`

If the request or data is unusable, the app displays an error and a
Retry button.

### Quiz Round

The app displays one question at a time with the question number,
progress indicator, and True and False buttons.

After the user selects an answer, the answer buttons are disabled for
that question. This prevents repeated taps from changing the score. A
correct answer adds one point.

Correct feedback displays `Correct!`. Incorrect feedback displays the
correct answer.

### Results Review

After question five, the app displays:

- Final score out of 5
- All five questions
- The selected answer for each question
- The correct answer
- Correct or incorrect status for each response

## Score Submission

The results screen includes a simulated score submission.

Example payload:

``` json
{
  "score": 3,
  "total": 5,
  "category": "Science & Nature"
}
```

The app clearly states:

``` text
Simulation only. No backend request was sent.
```

Fetching questions is a real HTTP GET request. The score submission in
this project is only a local simulation. A real score write would
require an instructor-provided backend endpoint and a successful
response from that backend before the app could claim the score was
saved.

## Replay

The `Replay with New Questions` action resets the quiz and makes a new
API request for a fresh set of questions.

## Error and Retry Testing

Network failure was tested by disabling the device’s internet connection
and starting the app.

The app correctly:

1.  Failed to retrieve the API data.
2.  Displayed a readable error instead of crashing.
3.  Displayed a Retry button.
4.  Loaded a new quiz after internet access was restored and Retry was
    selected.

## Verified Results

| Test                                                 | Result |
|------------------------------------------------------|--------|
| Live API request returned 5 questions                | PASS   |
| True/False question screen                           | PASS   |
| Incorrect answer feedback                            | PASS   |
| Correct answer feedback                              | PASS   |
| One-answer rule and repeated scoring prevention      | PASS   |
| Five-question round                                  | PASS   |
| Final score display                                  | PASS   |
| Review of all 5 answers                              | PASS   |
| Simulated score submission                           | PASS   |
| Simulation clearly identified as not a backend write | PASS   |
| Replay with fresh questions                          | PASS   |
| Network failure state                                | PASS   |
| Retry after restoring internet                       | PASS   |
| `flutter analyze`                                    | PASS   |

During the verified test round, the final score was `3 / 5`. This was
the result of that test run and is not hard-coded.

## Project Structure

``` text
science_signal/
├── android/
├── ios/
├── lib/
│   └── main.dart
├── linux/
├── macos/
├── web/
├── windows/
├── pubspec.yaml
├── pubspec.lock
└── README.md
```

The main Activity 15 implementation is in `lib/main.dart`.

## GET Request vs Score Submission

The question fetch is a real REST read:

``` text
GET request -> Open Trivia Database -> JSON response -> Flutter quiz
```

The score submission is different. No backend score endpoint is used, so
the app simulates the submission locally and clearly reports that no
backend request was sent.

A real cloud write would require a supported endpoint, the required
payload, a network request, and backend confirmation.

## Limitations

- Testing was completed on one device setup.
- Internet access is required to retrieve a quiz.
- Open Trivia Database is an external service and may be unavailable or
  rate-limited.
- Score submission is simulated because no backend score endpoint is
  used.
- The project does not claim that simulated scores are stored remotely.

## Repository

``` text
https://github.com/harshitjain25/science-signal
```

## Summary

Science Signal demonstrates how a Flutter app can read live JSON data
from a REST API and turn asynchronous network results into an
interactive quiz. The project handles loading, validation, failure,
retry, scoring, answer review, replay, and a clearly labeled simulated
score submission.
