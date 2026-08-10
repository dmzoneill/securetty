.PHONY: setup build rebuild rebuild-agents up env aliases egress omniroute ollama certs scan migrate down nuke test lint audit skillsaw eval

PC := cd $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST)))) && podman-compose

help:
	@echo "securetty — prefer 'securetty <command>' for interactive use"
	@echo ""
	@echo "  setup / build / rebuild / rebuild-agents  Image lifecycle"
	@echo "  up / down / nuke                          Service lifecycle"
	@echo "  env / aliases / certs / egress            Configuration"
	@echo "  omniroute / ollama                        Provider setup"
	@echo "  scan / audit / test                       Security + linting"
	@echo "  migrate                                   Remove agents from host"

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
down:
	$(PC) down
nuke:
	$(PC) down -v
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
test:
	find roles/ scripts/ -name '*.sh' -not -path '*/templates/*' | xargs shellcheck -x -S warning 2>/dev/null || true
	yamllint -d '{extends: default, rules: {line-length: disable, truthy: disable}}' group_vars/ roles/*/tasks/ site.yml scan.yml migrate.yml 2>/dev/null || true
	ansible-lint site.yml 2>/dev/null || true
audit:
	podman run --rm securetty_dev bash -c 'echo "=== npm audit ===" && npm audit --audit-level=high -g 2>/dev/null; echo "=== pip-audit ===" && pip-audit --desc 2>/dev/null || true'
skillsaw:
	podman run --rm -v $$(pwd):/workspace:Z ghcr.io/stbenjam/skillsaw:latest --strict
eval:
	npx promptfoo@latest eval --config evals/promptfooconfig.yaml
lint: test
