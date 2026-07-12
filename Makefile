SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: unit static integration build verify

unit:
	bats tests/unit

static:
	scripts/ci-static.sh

integration:
	./scripts/test-integration.sh

build:
	scripts/build-iso.sh

verify:
	scripts/verify-artifacts.sh
