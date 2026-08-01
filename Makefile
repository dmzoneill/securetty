.PHONY: env check-env build rebuild up down shell lockdown unlock \
       scan-secrets migrate status age nuke install-aliases setup-omniroute help

help:
	@echo "securetty — sandboxed AI development environment"
	@echo ""
	@echo "Setup:"
	@echo "  make env            Generate .env from .env.example"
	@echo "  make check-env      Validate .env exists and has keys"
	@echo "  make install-aliases  Install shell aliases (agent → container)"
	@echo ""
	@echo "Container:"
	@echo "  make build          Build container image"
	@echo "  make rebuild        Force rebuild (no cache, fresh delayed versions)"
	@echo "  make up             Start container + services"
	@echo "  make down           Stop everything"
	@echo "  make shell          Open shell in new container"
	@echo "  make nuke           Remove container + all volumes"
	@echo ""
	@echo "Security:"
	@echo "  make lockdown       Air-gap container network"
	@echo "  make unlock         Reconnect network"
	@echo "  make scan-secrets   Scan history files for leaked secrets"
	@echo "  make migrate        Remove AI agents from host"
	@echo ""
	@echo "Info:"
	@echo "  make status         Show container/network/volume state"
	@echo "  make age            Show image age and agent versions"

env:
	@bash scripts/generate-env.sh .env

check-env:
	@if [ ! -f .env ]; then \
		echo "ERROR: .env not found. Run: make env"; \
		exit 1; \
	fi
	@keys_set=0; \
	while IFS='=' read -r key val; do \
		[ -z "$$key" ] && continue; \
		case "$$key" in \#*) continue ;; esac; \
		if [ -n "$$val" ]; then keys_set=$$((keys_set + 1)); fi; \
	done < .env; \
	if [ "$$keys_set" -eq 0 ]; then \
		echo "WARNING: No API keys set in .env. Agents will need auth inside container."; \
	else \
		echo "$$keys_set API key(s) configured in .env"; \
	fi

build: check-env
	./securetty build

rebuild: check-env
	./securetty rebuild

up: env
	./securetty up

down:
	./securetty down

shell:
	./securetty shell

lockdown:
	./securetty lockdown

unlock:
	./securetty unlock

setup-omniroute:
	bash scripts/setup-omniroute.sh

scan-secrets:
	bash scripts/scan-secrets.sh

migrate:
	bash scripts/migrate-from-host.sh

status:
	./securetty status

age:
	./securetty age

nuke:
	./securetty nuke

install-aliases:
	@target="$$HOME/.bashrc.d/scripts.d/99-securetty.sh"; \
	cp scripts/securetty-aliases.sh "$$target"; \
	chmod +x "$$target"; \
	echo "Installed aliases to $$target"; \
	echo "Source it: source $$target"; \
	echo ""; \
	echo "After migration, remove old aliases from 00-aliases.sh:"
	@grep -n 'claude\|codex\|gemini\|headroom' "$$HOME/.bashrc.d/scripts.d/00-aliases.sh" 2>/dev/null \
		| sed 's/^/  /' || true
