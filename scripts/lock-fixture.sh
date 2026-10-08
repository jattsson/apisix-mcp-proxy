#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .test
docker run --rm -v "$PWD/fixtures/java:/fixture" -w /fixture gradle:9.7.1-jdk25@sha256:e06837018d077ee7f1218e53499425ca7615702ad58856d980c154caa17eb093 gradle --no-daemon dependencies --write-locks > .test/dependency-lock.log
tail -5 .test/dependency-lock.log
