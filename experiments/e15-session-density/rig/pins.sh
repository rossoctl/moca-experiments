#!/usr/bin/env bash
# shellcheck disable=SC2034  # read by lib.sh, bootstrap.sh and setup.sh
# experiments/e15-session-density/rig/pins.sh -- every artifact the fresh-metal profile downloads or pulls, pinned by version
# and checksum (SPEC §13). Sourced by lib.sh, never run; no side effects. The aws-prelim profile
# uses none of these (its toolchain, Firecracker and base snapshot were already on that host).
#
# Rule: a pin that cannot be determined is left EMPTY, never guessed. bootstrap.sh and setup.sh
# refuse to run while any name in E15_PINS is empty (lib.sh e15_require_pins).
#
# Sources, read 2026-11-03:

# Go: https://go.dev/dl/?mode=json&include=all (go1.26.0 linux-amd64). 1.26.0 exactly, because
# lib.sh e15_goenv sets GOTOOLCHAIN=go1.26.0 (the toolchain the preliminary rig built with); with
# that version installed locally the go command never downloads another toolchain.
E15_GO_VERSION=1.26.0
E15_GO_URL=https://go.dev/dl/go1.26.0.linux-amd64.tar.gz
E15_GO_SHA256=aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235

# Node: https://nodejs.org/dist/v22.23.4/SHASUMS256.txt (latest 22.x, LTS "Jod", 2026-10-20).
E15_NODE_VERSION=22.23.4
E15_NODE_URL=https://nodejs.org/dist/v22.23.4/node-v22.23.4-linux-x64.tar.gz
E15_NODE_SHA256=b8492284c76a54baf58d61668dd0e41ee0fc98adabf9503d30f05d08f55b4406

# pnpm, through Node's bundled corepack: https://registry.npmjs.org/pnpm (latest 9.x). The pin is
# the registry's sha512 integrity of pnpm-9.15.9.tgz, in hex; corepack checks it
# (`pnpm@9.15.9+sha512.<hex>`).
E15_PNPM_VERSION=9.15.9
E15_PNPM_SHA512=68046141893c66fad01c079231128e9afb89ef87e2691d69e4d40eee228988295fd4682181bae55b58418c3a253bde65a505ec7c5f9403ece5cc3cd37dcf2531

# Firecracker + jailer: the release's own firecracker-v1.17.0-x86_64.tgz.sha256.txt, re-computed
# here over the downloaded tarball (they agree).
E15_FC_VERSION=v1.17.0
E15_FC_URL=https://github.com/firecracker-microvm/firecracker/releases/download/v1.17.0/firecracker-v1.17.0-x86_64.tgz
E15_FC_SHA256=06094a1108ae9e82aa4c23a775aa92758f53f1175d422270d9d6162cb9ade558

# grpcurl (lib.sh gexec, setup.sh's end-to-end check): the release's grpcurl_1.9.4_checksums.txt.
E15_GRPCURL_VERSION=1.9.4
E15_GRPCURL_URL=https://github.com/fullstorydev/grpcurl/releases/download/v1.9.4/grpcurl_1.9.4_linux_x86_64.tar.gz
E15_GRPCURL_SHA256=97e13d58d2733a0e62cd2571d1d5f0c02823f0d25282f08bddedf1ad9c5d1736

# Guest kernel: Firecracker's CI kernel, the source moca v0.9.0 documents
# (deploy/microvm/P4-ON-P6.md "Build the golden snapshot", step 1: the spec.ccfc.min bucket). That
# recipe takes "the newest CI build"; E15 pins one build instead: vmlinux-6.18.44, the version the
# P4 verified run and the preliminary rig used, from the last CI build that published it. The
# bucket publishes no checksum; this sha256 was computed here over two downloads (identical).
E15_KERNEL_NAME=vmlinux-6.18.44
E15_KERNEL_URL=https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/20260909-a8e1c3830545-0/x86_64/vmlinux-6.18.44
E15_KERNEL_SHA256=d8ced68bd61e27b6813e2c993cc53a4029c59e13210672180591c84109684fe4

# Guest rootfs source: moca v0.9.0's sandbox image. .github/workflows/build.yaml publishes a v*
# tag as the semver tag "0.9.0" (no "v"). Index digest from ghcr.io's manifest endpoint; its
# image config carries org.opencontainers.image.revision=c13d55649777e69ec7649d6fa8c08f4acb1f4e2e
# (= E15_MOCA_PIN) and version 0.9.0. The amd64 entry is kept too: build-rootfs.sh records
# whichever digest podman reports, and either is this image.
E15_SANDBOX_IMAGE_TAG=0.9.0
E15_SANDBOX_IMAGE_DIGEST=sha256:e8207aef109eeb16e47885a069a76242a5c3a08259e4a09a50d2a0fea0b97e91
E15_SANDBOX_IMAGE_AMD64_DIGEST=sha256:c2d4d8c6243720373a5211a06fccea4fa97bd539cb9d884777e1de4a0d3092ed
E15_SANDBOX_IMAGE=ghcr.io/rossoctl/moca-remote-worker@$E15_SANDBOX_IMAGE_DIGEST

# E15's Redis (podman refuses a reference with both a tag and a digest, so by digest only): the
# index digest of docker.io/library/redis:7-alpine.
E15_METAL_REDIS_IMAGE=docker.io/library/redis@sha256:8da19c7399dca900c6822a1cf30f9d2285585e2c4b457ff4095b0f4500054d3f

# The names e15_require_pins checks.
E15_PINS=(E15_GO_VERSION E15_GO_URL E15_GO_SHA256 E15_NODE_VERSION E15_NODE_URL E15_NODE_SHA256
  E15_PNPM_VERSION E15_PNPM_SHA512 E15_FC_VERSION E15_FC_URL E15_FC_SHA256
  E15_GRPCURL_VERSION E15_GRPCURL_URL E15_GRPCURL_SHA256 E15_KERNEL_NAME E15_KERNEL_URL
  E15_KERNEL_SHA256 E15_SANDBOX_IMAGE_DIGEST E15_SANDBOX_IMAGE_AMD64_DIGEST E15_METAL_REDIS_IMAGE)
