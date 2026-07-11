#!/usr/bin/env bash
#
# nokogiri/mayhem/build.sh — build nokogiri's vendored Gumbo HTML5 parser fuzz harness as a
# sanitized libFuzzer target (+ a standalone reproducer).
#
# FUZZED SURFACE: gumbo-parser/fuzzer/parse_fuzzer.cc drives gumbo_parse_with_options() over
# attacker-controlled bytes — the C HTML5 tokenizer/tree-builder in gumbo-parser/src/*.c
# (parser, tokenizer, char_ref, utf8, attribute, foreign/svg attrs, vectors, hashmaps). This is
# the exact target OSS-Fuzz builds (projects/nokogiri/build.sh → `make oss-fuzz`). It does NOT
# touch libxml2/libxslt — those are separate vendored libs not wired to a fuzz harness here.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile libgumbo ITSELF with $SANITIZER_FLAGS so the parser code
# (not just the harness) is instrumented, plus -fsanitize=fuzzer-no-link for coverage.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
export SRC
cd "$SRC"

GUMBO="$SRC/gumbo-parser"
HARNESS_DIR="$SRC/mayhem/harnesses"

# Coverage instrumentation for the corpus-distillation path; ASan/UBSan come from SANITIZER_FLAGS.
COV="-fsanitize=fuzzer-no-link"

# ── 1) Build libgumbo.a WITH sanitizers + coverage (the fuzzed parser is instrumented) ─────────
# gumbo-parser/src/Makefile builds libgumbo.a from the *.o via make's default rules; it honours
# $CC, $AR and appends to $CFLAGS. Build OUT OF TREE (copy src to a scratch dir) so we never
# leave sanitized .o/.a behind in gumbo-parser/src — that would poison test.sh's clean rebuild.
SRCDIR="$SRC/mayhem-build/gumbo-src"
rm -rf "$SRCDIR"; mkdir -p "$(dirname "$SRCDIR")"; cp -a "$GUMBO/src" "$SRCDIR"
make -C "$SRCDIR" clean >/dev/null 2>&1 || true
make -C "$SRCDIR" -j"$MAYHEM_JOBS" libgumbo.a \
    CC="$CC" AR="${AR:-llvm-ar}" \
    CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV -std=c99 -Wall"
LIBGUMBO="$SRCDIR/libgumbo.a"
[ -f "$LIBGUMBO" ] || { echo "ERROR: libgumbo.a not built" >&2; exit 1; }

# Standalone run-once driver (no libFuzzer runtime) compiled once.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $COV -c "$HARNESS_DIR/standalone_main.c" -o "$SRC/mayhem-build/standalone_main.o"

# ── 2) Build parse_fuzzer twice: libFuzzer target + standalone reproducer ──────────────────────
INC="-I$GUMBO/src"

# libFuzzer target -> /mayhem/parse_fuzzer
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $COV $INC \
    "$GUMBO/fuzzer/parse_fuzzer.cc" $LIB_FUZZING_ENGINE "$LIBGUMBO" \
    -o "/mayhem/parse_fuzzer"

# standalone reproducer -> /mayhem/parse_fuzzer-standalone
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $COV $INC \
    "$GUMBO/fuzzer/parse_fuzzer.cc" "$SRC/mayhem-build/standalone_main.o" "$LIBGUMBO" \
    -o "/mayhem/parse_fuzzer-standalone"

echo "built parse_fuzzer (+ standalone)"

echo "build.sh complete:"
ls -la /mayhem/parse_fuzzer /mayhem/parse_fuzzer-standalone 2>&1 || true
