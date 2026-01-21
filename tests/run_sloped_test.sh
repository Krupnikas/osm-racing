#!/bin/bash

# Скрипт для запуска теста наклонных поверхностей
# Использование: ./tests/run_sloped_test.sh [--visual]

GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
PROJECT_PATH="/Users/sergey/webProjects/osm-racing"
TEST_SCENE="tests/test_sloped_terrain.tscn"

# Проверяем аргументы
if [ "$1" == "--visual" ]; then
    echo "Running sloped terrain test with visualization..."
    "$GODOT" --path "$PROJECT_PATH" "$TEST_SCENE"
else
    echo "Running sloped terrain test (headless)..."
    "$GODOT" --path "$PROJECT_PATH" "$TEST_SCENE" --headless
fi

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Test PASSED"
else
    echo "✗ Test FAILED (exit code: $EXIT_CODE)"
fi

exit $EXIT_CODE
