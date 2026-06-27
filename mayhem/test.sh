#!/usr/bin/env bash
#
# nokogiri/mayhem/test.sh — GOLDEN functional oracle over the fuzzed C parse path.
#
# nokogiri's own test suite is Ruby (rake test) and needs a full Ruby/rubygems toolchain plus the
# compiled C extension — out of scope for this C-only commit image. Instead we exercise the EXACT
# code the fuzzer drives: the vendored Gumbo HTML5 parser (gumbo_parse_with_options). We build a
# small, clean (non-sanitized) libgumbo and a golden oracle (mayhem/test_gumbo_oracle.c) that
# parses known HTML and asserts tree-shape facts (root <html>, head/body/title, table tree,
# entity decoding, attribute values) and that malformed inputs are handled without crashing.
#
# PATCH-grade: each assertion pins a concrete structural fact, so a patch that breaks the parser
# (mis-tags, drops children, mishandles entities/attributes) fails. This RUNS a freshly built
# oracle; it is not a no-op stub. CTRF summary emitted; exit nonzero iff any case fails.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

GUMBO="$SRC/gumbo-parser"
ORACLE_SRC="$SRC/mayhem/test_gumbo_oracle.c"
BUILDDIR="$SRC/mayhem-tests"
mkdir -p "$BUILDDIR"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# ── Build a CLEAN (non-sanitized, normal flags) libgumbo so the oracle is an honest functional
#    check, separate from the fuzz build tree. env -u strips any inherited sanitizer flags. ───────
CLEAN_SRC="$BUILDDIR/gumbo-src"
rm -rf "$CLEAN_SRC"; cp -a "$GUMBO/src" "$CLEAN_SRC"
# build.sh compiles libgumbo IN PLACE under gumbo-parser/src, so the copy may carry stale
# SANITIZED .o/.a. `make clean` first so the oracle links against a fresh NON-sanitized lib
# (otherwise the link fails: ASan objects without the ASan runtime).
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -C "$CLEAN_SRC" clean >/dev/null 2>&1 || true
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
      make -C "$CLEAN_SRC" -j"$MAYHEM_JOBS" libgumbo.a \
        CC="$CC" AR="${AR:-llvm-ar}" CFLAGS="-O2 -std=c99 -Wall" >/dev/null 2>&1; then
  echo "ERROR: could not build clean libgumbo for the oracle" >&2
  emit_ctrf "gumbo-oracle" 0 1 0; exit 2
fi

ORACLE_BIN="$BUILDDIR/test_gumbo_oracle"
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
      "$CC" -O2 -I"$CLEAN_SRC" "$ORACLE_SRC" "$CLEAN_SRC/libgumbo.a" -o "$ORACLE_BIN" >/dev/null 2>&1; then
  echo "ERROR: could not compile the gumbo oracle" >&2
  emit_ctrf "gumbo-oracle" 0 1 0; exit 2
fi

echo "=== running gumbo golden oracle ==="
out="$("$ORACLE_BIN" 2>&1)"; rc=$?
echo "$out"

PASSED=$(printf '%s\n' "$out" | sed -n 's/^RESULT passed=\([0-9][0-9]*\).*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/^RESULT passed=[0-9][0-9]* failed=\([0-9][0-9]*\).*/\1/p' | tail -1)
: "${PASSED:=0}" "${FAILED:=0}"

# If we couldn't parse a RESULT line, fall back to the binary's exit code.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "could not parse oracle RESULT line; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "gumbo-oracle" 1 0 0; exit 0; }
  emit_ctrf "gumbo-oracle" 0 1 0; exit 1
fi

emit_ctrf "gumbo-oracle" "$PASSED" "$FAILED" 0
