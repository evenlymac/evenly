#!/bin/zsh
# Пересоздаёт core/golden/*.f32 из Swift-реализации (нужен swiftc).
set -e
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
swiftc -O Sources/EvenlyDSP/Compressor.swift core/golden/swift/main.swift -o $T/gen
$T/gen core/golden/scenarios.json core/golden
rm -rf $T
