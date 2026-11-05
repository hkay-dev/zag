#!/bin/sh
# check.sh: the one quick check, a debug build. Runs from any folder.
set -eu
cd "$(dirname "$0")/.."
mise exec zig@0.17.0 -- zig build
