#!/bin/bash

# Скрипт для запуска теста высот земли
# Использование: ./tests/run_terrain_test.sh [--visual]

GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
PROJECT_PATH="/Users/sergey/webProjects/osm-racing"
TEST_SCENE="tests/test_terrain_elevation_runner.tscn"

# Проверяем аргументы
if [ "$1" == "--visual" ]; then
    echo "Running terrain elevation test with visualization..."
    "$GODOT" --path "$PROJECT_PATH" "$TEST_SCENE"
else
    echo "Running terrain elevation test (headless)..."
    "$GODOT" --path "$PROJECT_PATH" "$TEST_SCENE" --headless
fi

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Test PASSED"
else
    echo "✗ Test FAILED (exit code: $EXIT_CODE)"
fi

exit $EXIT_CODE
