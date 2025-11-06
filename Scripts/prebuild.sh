#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
CONFIG_DIR="$ROOT_DIR/Configs"

printf "Preparing build artifacts...\n"

mkdir -p "$ROOT_DIR/Derived"
cp -R "$CONFIG_DIR" "$ROOT_DIR/Derived/Configs"

printf "Configuration assets copied to Derived/Configs\n"
