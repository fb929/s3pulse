SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

COMPOSE ?= docker compose
# PROFILE / SELFTEST_DURATION are forwarded to compose ONLY when given on the
# command line (make run PROFILE=load). Otherwise .env (then compose defaults) wins,
# because shell environment would override .env during compose interpolation.
PROFILE ?=
SELFTEST_DURATION ?=
FORWARD_ENV := $(if $(PROFILE),PROFILE=$(PROFILE)) $(if $(SELFTEST_DURATION),SELFTEST_DURATION=$(SELFTEST_DURATION))
# Lint must work before .env exists: fall back to .env.example for compose validation.
LINT_ENV_FILE := $(if $(wildcard .env),,--env-file .env.example)

SCRIPTS := scripts/entrypoint.sh scripts/run_scenario.sh scripts/sink.sh sinks/stub.sh sinks/pushgateway.sh sinks/http_json.sh

.PHONY: help build up run selftest down lint lint-shell lint-compose lint-flags clean-results

help: ## Show this help
	@grep --extended-regexp '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

build: ## Build the runner image
	$(COMPOSE) build s3pulse-runner

up: build ## Start the runner once in the background (PROFILE from .env, or make up PROFILE=load)
	env $(FORWARD_ENV) $(COMPOSE) up --detach s3pulse-runner

run: build ## Run once in the foreground (PROFILE from .env, or make run PROFILE=load)
	env $(FORWARD_ENV) $(COMPOSE) run --rm s3pulse-runner

selftest: ## End-to-end smoke test against the local S3 server (make selftest PROFILE=load SELFTEST_DURATION=10)
	env $(FORWARD_ENV) $(COMPOSE) --profile selftest build s3pulse-selftest
	env $(FORWARD_ENV) $(COMPOSE) --profile selftest run --rm s3pulse-selftest; \
	status=$$?; \
	$(COMPOSE) --profile selftest down --remove-orphans; \
	exit $$status

down: ## Stop and remove containers (all profiles)
	$(COMPOSE) --profile selftest down --remove-orphans

lint: lint-shell lint-compose lint-flags ## Run all checks

lint-shell: ## shellcheck + set -euo pipefail check
	shellcheck --shell=bash $(SCRIPTS)
	@for file in $(SCRIPTS); do \
		grep --quiet --fixed-strings 'set -euo pipefail' "$$file" || { echo "missing 'set -euo pipefail': $$file"; exit 1; }; \
	done
	@echo "shell: ok"

lint-compose: ## Validate compose files (default, selftest profile, monitoring override)
	$(COMPOSE) $(LINT_ENV_FILE) config --quiet
	$(COMPOSE) $(LINT_ENV_FILE) --profile selftest config --quiet
	$(COMPOSE) $(LINT_ENV_FILE) --file docker-compose.yml --file docker-compose.monitoring.yml config --quiet
	@echo "compose: ok"

lint-flags: ## Fail on short-form CLI flags (bash test operators and builtins without long forms are exempt)
	@hits="$$(grep --line-number --extended-regexp --regexp='(^|[[:space:]"])-[a-zA-Z]([[:space:]"]|$$)' $(SCRIPTS) Makefile docker-compose.yml docker-compose.monitoring.yml Dockerfile \
		| grep --invert-match --extended-regexp --regexp='\[\[ |\bread -r\b|\bmapfile -t\b|\bcommand -v\b' || true)"; \
	if [[ -n "$$hits" ]]; then printf '%s\n' "$$hits"; echo "short-form CLI flags found"; exit 1; fi
	@echo "flags: ok"

clean-results: ## Delete local results (RESULTS_PATH from .env, default ./results)
	@results_path="$$(grep --extended-regexp '^RESULTS_PATH=' .env 2>/dev/null | cut --delimiter='=' --fields=2-)"; \
	results_path="$${results_path:-./results}"; \
	echo "removing $${results_path}/*"; rm --recursive --force "$${results_path:?}"/*
