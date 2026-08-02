.PHONY: setup build up env aliases omniroute ollama scan migrate down nuke status help

help:
	@echo "securetty — sandboxed AI development environment (Ansible)"
	@echo ""
	@echo "Setup:"
	@echo "  make setup          Full setup (build, configure, aliases)"
	@echo "  make build          Build container images only"
	@echo "  make up             Start services only"
	@echo "  make env            Regenerate .env files"
	@echo "  make aliases        Install shell aliases"
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
	ansible-playbook site.yml --tags build

up:
	ansible-playbook site.yml --tags up

env:
	ansible-playbook site.yml --tags env

aliases:
	ansible-playbook site.yml --tags aliases

omniroute:
	ansible-playbook site.yml --tags omniroute

ollama:
	ansible-playbook site.yml --tags ollama

scan:
	ansible-playbook site.yml --tags scan

migrate:
	ansible-playbook site.yml --tags migrate

down:
	cd $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST)))) && podman-compose down

nuke:
	cd $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST)))) && podman-compose down -v

status:
	@podman ps -a --format "table {{.Names}}\t{{.Status}}" | grep securetty || echo "No containers running"
