.PHONY: setup build rebuild rebuild-agents up env aliases egress omniroute ollama scan migrate down nuke status help

help:
	@echo "securetty — sandboxed AI development environment (Ansible)"
	@echo ""
	@echo "Setup:"
	@echo "  make setup          Full setup (build, configure, aliases)"
	@echo "  make build          Build container images only"
	@echo "  make rebuild-agents Rebuild dev+services only (skip base/devbase)"
	@echo "  make up             Start services only"
	@echo "  make env            Regenerate .env files"
	@echo "  make aliases        Install shell aliases"
	@echo "  make egress         Load egress whitelist rules"
	@echo "  make omniroute      Configure omniroute providers"
	@echo "  make ollama         Pull ollama models"
	@echo ""
	@echo "Security:"
	@echo "  make scan           Scan history for leaked secrets"
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
	ansible-playbook site.yml --tags prereqs,build -e securetty_force_rebuild=true -e securetty_skip_devbase=true

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
