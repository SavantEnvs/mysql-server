#!/usr/bin/env bash
#
# mayhem/build.sh — build the MySQL Router libFuzzer harnesses (upstream's own routertest_fuzz_*
# targets) with ASan+UBSan, plus a normal-flags build of the router unit tests that mayhem/test.sh runs.
#
# Runs in the commit image as `mayhem` in /mayhem. Everything MySQL needs (boost, protobuf, icu, libevent,
# zlib, lz4, zstd, rapidjson, googletest) is bundled in the tree, so nothing is fetched at build time;
# the only external deps are apt -dev packages installed by the Dockerfile. Build dirs live under the
# gitignored build/ so `git clean -ffdX` removes them.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
mkdir -p build

# Configure only on a fresh build dir. A re-run may resolve the compiler differently (ccache shim in the
# image build vs /usr/bin/clang), which makes CMake wipe the cache and re-default WEBAUTHN to ON, which
# then fails for lack of libudev. The cached configuration is what the re-run must reuse anyway.
configure() { local dir="$1"; shift; [ -f "$dir/CMakeCache.txt" ] || env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake -S . -B "$dir" "${COMMON_CMAKE[@]}" "$@"; }

# Router fuzzers + unit tests are only defined when WITH_UNIT_TESTS=ON.
COMMON_CMAKE=(-G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DWITH_SSL=system -DWITH_UNIT_TESTS=ON -DWITH_AUTHENTICATION_WEBAUTHN=OFF
  -DWITH_AUTHENTICATION_LDAP=OFF -DWITH_NUMA=OFF)

TARGETS=()
for mf in mayhem/Mayhemfile_*; do TARGETS+=("${mf#mayhem/Mayhemfile_}"); done

# --- 1) sanitized fuzz build ------------------------------------------------------------------------
# lsan_off: leak detection off for every executable (build tools included), at link time.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/lsan_off.o
# Standalone driver compiled as C so its LLVMFuzzerTestOneInput reference keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o

# -fsanitize=fuzzer-no-link instruments the whole project (not just the harness TU) for coverage.
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
configure build/fuzz \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O1" -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O1" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $SRC/build/lsan_off.o"
ninja -C build/fuzz -j"$MAYHEM_JOBS" "${TARGETS[@]}"

for t in "${TARGETS[@]}"; do
  bin="$(find build/fuzz -name "$t" -type f -perm -u+x | head -1)"
  [ -n "$bin" ] || { echo "build.sh: $t was not built" >&2; exit 1; }
  cp -f "$bin" "/mayhem/$t"
  # Same link line as the fuzzer, with the run-once driver instead of libFuzzer's main.
  link="$(ninja -C build/fuzz -t commands "${bin#build/fuzz/}" | tail -1)"
  link="${link#: && }"; link="${link%% && cd *}"
  link="${link/ -fsanitize=fuzzer / $SRC/build/standalone_main.o }"
  link="$(sed "s# -o [^ ]*# -o /mayhem/$t-standalone#" <<<"$link")"
  (cd build/fuzz && bash -c "$link")
done

# --- 2) normal-flags build of the router unit tests (the oracle for mayhem/test.sh) -------------------
TEST_TARGETS=(routertest_harness_string_utils routertest_http_base64 routertest_http_auth_method
  routertest_http_auth_backend routertest_http_kdf_pbkdf2 routertest_http_kdf_sha_crypt
  routertest_http_passwd routertest_http_uri routertest_router_uri
  routertest_mysql_protocol_classic_protocol routertest_mysql_protocol_classic_protocol_binary
  routertest_mysql_protocol_classic_protocol_frame routertest_mysql_protocol_classic_protocol_message
  routertest_mysql_protocol_classic_protocol_session_track routertest_mysql_protocol_classic_protocol_wire
  routertest_routing_guidelines_parser routertest_routing_sql_splitting_allowed)
configure build/test \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
ninja -C build/test -j"$MAYHEM_JOBS" "${TEST_TARGETS[@]}"
