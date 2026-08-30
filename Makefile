# mackas
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

SHELL := /bin/bash

.PHONY: test check lint shellcheck syntax pytest help

help:
	@echo "make test        Run everything: shellcheck, bash 3.2 syntax, bats, and the python suite."
	@echo "make lint        Run shellcheck only."
	@echo "make syntax      Parse-check under macOS' stock bash 3.2 only."
	@echo "make pytest      Run the Python unittest suite only (mirrord, analyzer, sampler)."
	@echo "make check       Run './mackas check' (preflight; changes nothing)."

test:
	./run-tests.sh

lint shellcheck:
	shellcheck -s bash mackas bin/docker run-tests.sh \
		tests/mock/container tests/mock/bin/*

syntax:
	/bin/bash -n mackas
	/bin/bash -n bin/docker
	python3 -m py_compile mirror-server/mackas-mirrord

# The Python unittest suite (mirrord, buildstats analyzer, overhead sampler).
# `make test` runs this too, via run-tests.sh.
pytest:
	python3 -m unittest discover -s tests -p 'test_*.py' -v

# Not to be confused with `make test`: this runs the tool's own preflight.
check:
	./mackas check
