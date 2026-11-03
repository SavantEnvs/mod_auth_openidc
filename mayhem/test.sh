#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# Upstream's libcheck unit tests, built by mayhem/build.sh with the project's normal flags. Every
# result is parsed from libcheck's own summary line ("100%: Checks: N, Failures: F, Errors: E"), so a
# binary that is neutered to exit(0) prints no summary and the suite FAILS instead of passing blind.
T="$SRC/mayhem/build-test/project/test"
export srcdir="$SRC/test"
export CK_DEFAULT_TIMEOUT="${CK_DEFAULT_TIMEOUT:-60}"
unit_tests="test_cfg test_config test_util test_jose test_http test_cache test_proto test_handle test_state test_session test_oauth test_metadata test_metrics"

passed=0; failed=0
cd "$T" || { echo "test.sh: $T missing (build.sh builds it)" >&2; exit 1; }

for t in $unit_tests; do
  if [ ! -x "./$t" ]; then echo "FAIL: $t was not built" >&2; failed=$((failed + 1)); continue; fi
  out=$(./"$t" 2>&1); rc=$?
  summary=$(printf '%s\n' "$out" | grep -E '^[0-9]+%: Checks: [0-9]+, Failures: [0-9]+, Errors: [0-9]+' | tail -n1)
  if [ -z "$summary" ]; then
    echo "FAIL: $t printed no libcheck summary (rc=$rc)" >&2; failed=$((failed + 1)); continue
  fi
  n=$(printf '%s' "$summary" | sed -E 's/.*Checks: ([0-9]+),.*/\1/')
  f=$(printf '%s' "$summary" | sed -E 's/.*Failures: ([0-9]+),.*/\1/')
  e=$(printf '%s' "$summary" | sed -E 's/.*Errors: ([0-9]+).*/\1/')
  bad=$((f + e))
  [ "$n" -gt 0 ] || { echo "FAIL: $t ran 0 checks" >&2; failed=$((failed + 1)); continue; }
  if [ "$bad" -gt 0 ] || [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | grep -vE ':P:' | tail -n 30 >&2
    [ "$bad" -gt 0 ] || bad=1
    failed=$((failed + bad)); passed=$((passed + n - bad > 0 ? n - bad : 0))
  else
    passed=$((passed + n))
  fi
  echo "$t: $summary"
done

# Upstream's source guards (every START_TEST is registered, every directive is initialised/merged,
# auth_openidc.conf matches the code) and the seed-corpus replay, run by bash against the real tree.
for g in check_registration.sh check_directives.sh check_conf_reference.sh; do
  if bash "$SRC/test/$g" >/dev/null 2>&1; then passed=$((passed + 1)); echo "$g: ok"
  else echo "FAIL: $g" >&2; failed=$((failed + 1)); fi
done

emit_ctrf "libcheck" "$passed" "$failed" 0
