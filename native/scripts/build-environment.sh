#!/bin/bash
# Source after changing into native/. Keep intermediates on the project volume.
mkdir -p "$PWD/.build/tmp" "$PWD/.build/ModuleCache"
export TMPDIR="$PWD/.build/tmp/"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
