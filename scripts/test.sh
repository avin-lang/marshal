#!/bin/sh
# Builds marshal and runs every test: the unit tests, and the end-to-end tests, which drive the
# executable just built through $MARSHAL_BIN. $AVIN names the avin compiler (default: `avin` on
# PATH); arguments are passed to `avin test` (a filter, for one).
set -e
cd "$(dirname "$0")/.."
avin=${AVIN:-avin}
mkdir -p .avin/test
# Never the real take-slot directory: each end-to-end test gives its daemon one of its own.
export MARSHAL_TAKE_SLOT_DIR=
# marshal's own steps and types are this tree's, and the stock steps are compiled with $AVIN.
export MARSHAL_STOCK="$PWD/stock"
export AVIN="$avin"
"$avin" build . -o .avin/test/marshal
MARSHAL_BIN="$PWD/.avin/test/marshal" "$avin" test . "$@"
