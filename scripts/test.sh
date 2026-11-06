#!/bin/sh
# Builds marshal and runs every test: the unit tests, and the end-to-end tests, which drive the
# executable just built through $MARSHAL_BIN. $AVIN names the avin compiler (default: `avin` on
# PATH); arguments are passed to `avin test` (a filter, for one).
set -e
cd "$(dirname "$0")/.."
avin=${AVIN:-avin}
mkdir -p .avin/test
"$avin" build . -o .avin/test/marshal
MARSHAL_BIN="$PWD/.avin/test/marshal" "$avin" test . "$@"
