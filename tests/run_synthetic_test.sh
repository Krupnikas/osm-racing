#!/bin/bash

# Скрипт для запуска синтетического теста высот
# Использование: ./tests/run_synthetic_test.sh [--visual]

GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
PROJECT_PATH="/Users/sergey/webProjects/osm-racing"
TEST_SCENE="tests/test_synthetic_terrain.tscn"

# Проверяем аргументы
if [ "$1" == "--visual" ]; then
    echo "Running synthetic terrain test with visualization..."
    "$GODOT" --path "$PROJECT_PATH" "$TEST_SCENE"
else
    echo "Running synthetic terrain test (headless)..."
    "$GODOT" --path "$PROJECT_PATH" "$TEST_SCENE" --headless
fi

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Test PASSED"
else
    echo "✗ Test FAILED (exit code: $EXIT_CODE)"
fi

exit $EXIT_CODE
