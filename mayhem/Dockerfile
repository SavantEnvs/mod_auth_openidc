# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# Build dependencies: Apache + APR dev files (apxs), the libraries the module links, libcheck for
# the unit-test oracle, and the autotools the upstream tree needs (it ships no generated configure).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        apache2-dev libapr1-dev libaprutil1-dev libjansson-dev libcurl4-openssl-dev libssl-dev \
        libpcre2-dev zlib1g-dev check autoconf automake libtool pkg-config m4 make git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# cjose is cached in-image (pinned by commit, 0.8.1) so build.sh can rebuild it offline under the
# sanitizer flags. The distro libcjose is 0.6.2.x, which carries crashes fixed upstream; this is
# the same source OSS-Fuzz builds. build.sh compiles it; nothing is fetched at build time.
RUN mkdir -p /opt/toolchains/cjose-src \
 && git clone -q https://github.com/OpenIDC/cjose /opt/toolchains/cjose-src \
 && git -C /opt/toolchains/cjose-src checkout -q 6fdb5fe75a86acb9cd34ca2eb13d9e090a6df588 \
 && rm -rf /opt/toolchains/cjose-src/.git \
 && chown -R 2000:2000 /opt/toolchains/cjose-src

# jansson (the JSON parser every token/userinfo/metadata document goes through) is cached the same way,
# pinned to v2.14.1, so build.sh can rebuild it with the SanCov/ASan flags: the distro libjansson is
# uninstrumented and the fuzzer would see none of the parser.
RUN mkdir -p /opt/toolchains/jansson-src \
 && git clone -q https://github.com/akheron/jansson /opt/toolchains/jansson-src \
 && git -C /opt/toolchains/jansson-src checkout -q ed5cae4ed0621ef409510f94270c9f8f263736d0 \
 && rm -rf /opt/toolchains/jansson-src/.git \
 && chown -R 2000:2000 /opt/toolchains/jansson-src
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Anything a Dockerfile step materializes into the tree (downloaded fixtures, generated headers,
# vendored deps) MUST be committed or (re)created by build.sh: rlenv's patch grader runs
# `git clean -ffdX` before every graded build, so a gitignored, untracked file is gone by then and
# every honest patch scores zero (SPEC §6.2 item 16; verify-repo.sh checks it).
#
# OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). Bases minted with /opt/mayhem/ccache/prefill
# run the build under rlenv's pinned ccache, so the patch grader's first (otherwise cold) rebuild is
# warm — this is what keeps large C/C++ targets inside the build time limit. Older bases fall back to
# the plain build; a missing or stale pre-fill only costs a cold cache. Never enable ccache in
# build.sh or via ENV/PATH, and keep the compiler resolving by name (CC=clang) or nothing is cached.
RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
