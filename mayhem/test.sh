#!/usr/bin/env bash
#
# mayhem/test.sh — RUN MySQL Router's own gtest unit tests (built by mayhem/build.sh with normal flags)
# for the code the fuzz harnesses exercise: http base64/auth/kdf/passwd/uri, router uri, the classic
# protocol codec, the routing-guidelines parser and the routing SQL splitter. Each binary must report
# `[  PASSED  ] N tests` with N>0 and no FAILED line: a neutered binary prints nothing and counts as failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

dir="$SRC/build/test/runtime_output_directory"
passed=0; failed=0
for t in routertest_harness_string_utils routertest_http_base64 routertest_http_auth_method \
         routertest_http_auth_backend routertest_http_kdf_pbkdf2 routertest_http_kdf_sha_crypt \
         routertest_http_passwd routertest_http_uri routertest_router_uri \
         routertest_mysql_protocol_classic_protocol routertest_mysql_protocol_classic_protocol_binary \
         routertest_mysql_protocol_classic_protocol_frame routertest_mysql_protocol_classic_protocol_message \
         routertest_mysql_protocol_classic_protocol_session_track routertest_mysql_protocol_classic_protocol_wire \
         routertest_routing_guidelines_parser routertest_routing_sql_splitting_allowed; do
  if [ ! -x "$dir/$t" ]; then echo "FAIL $t: missing (mayhem/build.sh should have built it)"; failed=$((failed+1)); continue; fi
  out="$(cd "$dir" && timeout 600 "./$t" 2>&1)"; rc=$?
  n="$(sed -n 's/^\[  PASSED  \] \([0-9]*\) test.*/\1/p' <<<"$out" | tail -1)"
  nfail="$(grep -c '^\[  FAILED  \] .*\.' <<<"$out")"
  if [ "$rc" -eq 0 ] && [ "${n:-0}" -gt 0 ] && [ "$nfail" -eq 0 ]; then
    echo "ok   $t: $n passed"; passed=$((passed+n))
  else
    echo "FAIL $t: rc=$rc passed=${n:-0} failed-lines=$nfail"; echo "$out" | tail -5
    failed=$((failed+1)); passed=$((passed+${n:-0}))
  fi
done
emit_ctrf "gtest" "$passed" "$failed" 0
