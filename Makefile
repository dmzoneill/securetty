.PHONY: setup build rebuild rebuild-agents up env aliases egress omniroute ollama certs scan migrate down nuke status help test lint audit lockfiles skillsaw eval

help:
	@echo "securetty — sandboxed AI development environment (Ansible)"
	@echo ""
	@echo "Setup:"
	@echo "  make setup          Full setup (build, configure, aliases)"
	@echo "  make build          Build container images only"
	@echo "  make rebuild        Full rebuild (all layers)"
	@echo "  make rebuild-agents Rebuild dev only (skip base/devbase/services)"
	@echo "  make up             Start services only"
	@echo "  make env            Regenerate .env files"
	@echo "  make aliases        Install shell aliases"
	@echo "  make certs          Generate TLS certificates"
	@echo "  make egress         Load egress whitelist rules"
	@echo "  make omniroute      Configure omniroute providers"
	@echo "  make ollama         Pull ollama models"
	@echo ""
	@echo "Security:"
	@echo "  make scan           Scan history for leaked secrets"
	@echo "  make audit          Run npm audit + pip-audit inside container"
	@echo "  make lockfiles      Generate npm/pip lockfiles with hashes"
	@echo "  make migrate        Remove AI agents from host"
	@echo ""
	@echo "Lifecycle:"
	@echo "  make down           Stop all containers"
	@echo "  make nuke           Remove containers + volumes"
	@echo "  make status         Show container status"

setup:
	ansible-playbook site.yml

build:
	ansible-playbook site.yml --tags prereqs,build

rebuild:
	ansible-playbook site.yml --tags prereqs,build -e securetty_force_rebuild=true

rebuild-agents:
	ansible-playbook site.yml --tags prereqs,build -e securetty_force_rebuild=true -e securetty_skip_devbase=true -e securetty_dev_only=true

up:
	ansible-playbook site.yml --tags prereqs,up

env:
	ansible-playbook site.yml --tags prereqs,env

aliases:
	ansible-playbook site.yml --tags prereqs,aliases

egress:
	ansible-playbook site.yml --tags prereqs,egress

omniroute:
	ansible-playbook site.yml --tags prereqs,omniroute

ollama:
	ansible-playbook site.yml --tags prereqs,ollama

certs:
	ansible-playbook site.yml --tags prereqs,certs

scan:
	ansible-playbook scan.yml

migrate:
	ansible-playbook migrate.yml

down:
	cd $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST)))) && podman-compose down

nuke:
	cd $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST)))) && podman-compose down -v

status:
	@podman ps -a --format "table {{.Names}}\t{{.Status}}" | grep securetty || echo "No containers running"

test:
	@echo "=== shellcheck ==="
	find roles/ scripts/ -name '*.sh' -not -path '*/templates/*' | xargs shellcheck -x -S warning 2>/dev/null || true
	@echo "=== yamllint ==="
	yamllint -d '{extends: default, rules: {line-length: disable, truthy: disable}}' group_vars/ roles/*/tasks/ site.yml scan.yml migrate.yml 2>/dev/null || true
	@echo "=== ansible-lint ==="
	ansible-lint site.yml 2>/dev/null || true
	@echo "=== structure ==="
	@test -f AGENTS.md && echo "AGENTS.md: OK" || echo "AGENTS.md: MISSING"
	@test -f THREAT_MODEL.md && echo "THREAT_MODEL.md: OK" || echo "THREAT_MODEL.md: MISSING"
	@test -f SECURITY.md && echo "SECURITY.md: OK" || echo "SECURITY.md: MISSING"
	@lines=$$(wc -l < AGENTS.md 2>/dev/null || echo 999); test $$lines -le 150 && echo "AGENTS.md length: OK ($$lines lines)" || echo "AGENTS.md length: TOO LONG ($$lines lines, max 150)"

audit:
	podman run --rm securetty_dev bash -c 'echo "=== npm audit ===" && npm audit --audit-level=high -g 2>/dev/null; echo "=== pip-audit ===" && pip-audit --desc 2>/dev/null || true'

lockfiles:
	bash roles/containers/files/generate-lockfiles.sh @anthropic-ai/claude-code @openai/codex @google/gemini-cli cline opencode-ai @ampcode/cli @kilocode/cli @earendil-works/pi-ai

skillsaw:
	podman run --rm -v $$(pwd):/workspace:Z ghcr.io/stbenjam/skillsaw:latest --strict

eval:
	npx promptfoo@latest eval --config evals/promptfooconfig.yaml

lint: test
