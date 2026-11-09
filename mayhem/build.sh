#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# cjose and jansson are cached in the image (Dockerfile) so this script never touches the network;
# they are built below under each variant's own flags.
: "${CJOSE_SRC:=/opt/toolchains/cjose-src}"
: "${JANSSON_SRC:=/opt/toolchains/jansson-src}"
[ -f "$CJOSE_SRC/configure.ac" ] || { echo "build.sh: no cjose source at $CJOSE_SRC" >&2; exit 1; }
[ -f "$JANSSON_SRC/configure.ac" ] || { echo "build.sh: no jansson source at $JANSSON_SRC" >&2; exit 1; }

# Two out-of-tree autotools builds (gitignored via mayhem/.gitignore, so `git clean -ffdX` removes
# them and this script recreates them): build-fuzz = sanitized + coverage-instrumented library for
# the harnesses, build-test = the project's NORMAL flags for the unit-test oracle.
FUZZ_DIR="$SRC/mayhem/build-fuzz"
TEST_DIR="$SRC/mayhem/build-test"

# configure/automake inputs are generated into the (gitignored) source tree.
[ -f "$SRC/configure" ] && [ "$SRC/configure" -nt "$SRC/configure.ac" ] || ./autogen.sh >/dev/null

# build_variant <dir> <cflags>: jansson + cjose (static, same flags) + the module's static library.
# The module's loadable .so is not a fuzz artifact. --without-jq/--without-hiredis mirrors upstream's
# own OSS-Fuzz build; pcre2/zlib/curl/openssl/apr come from apt.
build_variant() {
  local dir=$1 cflags=$2 deps
  deps="$dir/deps"
  mkdir -p "$dir"
  rm -rf "$dir/jansson-src" && cp -a "$JANSSON_SRC" "$dir/jansson-src"
  ( cd "$dir/jansson-src"
    autoreconf -fi >/dev/null 2>&1
    ./configure --prefix="$deps" --disable-shared --enable-static CC="$CC" CFLAGS="$cflags" >/dev/null
    make -j"$MAYHEM_JOBS" >/dev/null
    make install >/dev/null )
  rm -rf "$dir/cjose-src" && cp -a "$CJOSE_SRC" "$dir/cjose-src"
  ( cd "$dir/cjose-src"
    autoreconf -fi >/dev/null 2>&1
    PKG_CONFIG_PATH="$deps/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
      ./configure --prefix="$deps" --disable-shared --enable-static CC="$CC" CFLAGS="$cflags" >/dev/null
    make -j"$MAYHEM_JOBS" >/dev/null
    make install >/dev/null )
  mkdir -p "$dir/project"
  ( cd "$dir/project"
    PKG_CONFIG_PATH="$deps/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
      "$SRC/configure" CC="$CC" CFLAGS="$cflags" --with-apxs=/usr/bin/apxs \
        --without-jq --without-hiredis --disable-shared >/dev/null )
}

# Compiler and tools are reached by name through PATH (SPEC §6.2 item 17). -fno-lto: apxs's CFLAGS
# carry -flto, which makes the linker discard sanitizer-coverage constructors. -include stddef.h keeps
# APR_OFFSETOF on the builtin (otherwise UBSan flags APR's NULL-based fallback in the brigade macros).
FUZZ_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 -fno-lto -include stddef.h"
build_variant "$FUZZ_DIR" "$FUZZ_CFLAGS"
P="$FUZZ_DIR/project"
make -C "$P/src" -j"$MAYHEM_JOBS" libauth_openidc.la >/dev/null
lib="$P/src/.libs/libauth_openidc.a"
[ -f "$lib" ] || { echo "build.sh: $lib was not built" >&2; exit 1; }

# The USE_* feature macros exist only in automake's AM_CFLAGS and change the layout of oidc_cfg_t, so
# the hand-compiled harness TUs must see exactly the set the library was built with.
feature_cflags=$(make -s -C "$P/src" --eval='oidc-print-am-cflags: ; @echo $(AM_CFLAGS)' oidc-print-am-cflags |
  tr ' ' '\n' | grep -E '^-D(USE_[A-Z0-9_]+|SSL_SUPPORT)$' | sort -u | tr '\n' ' ')

export PKG_CONFIG_PATH="$FUZZ_DIR/deps/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
pkgs="cjose jansson apr-1 apr-util-1 libcrypto libssl libcurl libpcre2-8"
apache_inc=$(apxs -q INCLUDEDIR)
# shellcheck disable=SC2046,SC2086
inc="-I$SRC/src -I$P/src -I$SRC/test -I$apache_inc $(pkg-config --cflags $pkgs)"
# shellcheck disable=SC2046,SC2086
libs="$(pkg-config --libs $pkgs) -lz -lm -lrt -lpthread"
hflags="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 -fno-lto -include stddef.h -DFUZZING $feature_cflags $inc"

# LeakSanitizer off at build time (SPEC §6.2 item 15).
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_DIR/lsan_off.o"
# shellcheck disable=SC2086
$CC $hflags -c "$SRC/test/util.c" -o "$FUZZ_DIR/util.o"
# shellcheck disable=SC2086
$CC $hflags -c "$SRC/test/stub.c" -o "$FUZZ_DIR/stub.o"

# 2) one libFuzzer binary + one run-once standalone reproducer per harness. The harness lives in
#    mayhem/harnesses: this old base has no upstream harness for the state-cookie header walk.
for src in "$SRC"/mayhem/harnesses/fuzz_*.c; do
  t=$(basename "$src" .c)
  # shellcheck disable=SC2086
  $CC $hflags -c "$src" -o "$FUZZ_DIR/$t.o"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "$FUZZ_DIR/$t.o" "$FUZZ_DIR/util.o" "$FUZZ_DIR/stub.o" \
      "$FUZZ_DIR/lsan_off.o" "$lib" $libs $LIB_FUZZING_ENGINE -o "$SRC/$t"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link "$STANDALONE_FUZZ_MAIN" "$FUZZ_DIR/$t.o" \
      "$FUZZ_DIR/util.o" "$FUZZ_DIR/stub.o" "$FUZZ_DIR/lsan_off.o" "$lib" $libs -o "$SRC/$t-standalone"
done

# 3) the project's own libcheck suite, NORMAL flags (no sanitizers, no -gdwarf-3, no fuzzer
#    instrumentation), so mayhem/test.sh only RUNS it. The libcheck binaries land in
#    build-test/project/test; the gitignored build-test dir is rebuilt here every time.
unset PKG_CONFIG_PATH
build_variant "$TEST_DIR" "-g -O2 -fPIC -fno-lto -include stddef.h $COVERAGE_FLAGS"
make -C "$TEST_DIR/project/src" -j"$MAYHEM_JOBS" libauth_openidc.la >/dev/null
make -C "$TEST_DIR/project/test" -j"$MAYHEM_JOBS" check TESTS= >/dev/null
