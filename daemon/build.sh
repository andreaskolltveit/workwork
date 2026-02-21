#!/bin/bash
# Build WorkWork daemon
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building workworkd..."
swiftc -O \
  -o "$SCRIPT_DIR/workworkd" \
  "$SCRIPT_DIR/WorkWorkDaemon.swift" \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework AppKit \
  -framework Foundation

echo "Built: $SCRIPT_DIR/workworkd"
