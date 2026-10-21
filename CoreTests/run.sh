#!/usr/bin/env bash
# Compiles and runs the unit tests for the app's platform-independent core
# (JSON streaming parser, graph expression engine, LaTeX parser, shape recognizer,
# flashcard scheduling, topic stats and study streaks).
# Works on macOS or Linux with a Swift 5.9+ toolchain: ./CoreTests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP=TutorNotes.swiftpm
OUT="$(mktemp -d)/core-tests"
swiftc -swift-version 5 -O -o "$OUT" CoreTests/main.swift \
  "$APP/Tutor/JSON.swift" "$APP/Math/Expression.swift" "$APP/Math/MathParser.swift" \
  "$APP/Canvas/ShapeRecognizer.swift" "$APP/Model/StudyCore.swift"
"$OUT"
