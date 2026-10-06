# Makefile de sysadmin-toolkit
#
#   make lint          ShellCheck sobre scripts, biblioteca y pruebas
#   make test          pruebas automáticas (bats)
#   make test-real     incluye las pruebas que crean usuarios de verdad
#                      (solo como root en un contenedor o VM desechable)
#   make herramientas  instala bats en .tools/ con npm (no se sube a git)

SHELL := /bin/bash
.DEFAULT_GOAL := ayuda

SCRIPTS := $(wildcard bin/*.sh) $(wildcard lib/*.sh)
PRUEBAS := $(wildcard tests/*.bats) tests/ayudante.bash

# Se usa el bats del sistema si existe; si no, el instalado en .tools/.
BATS ?= $(shell command -v bats 2> /dev/null || echo .tools/node_modules/.bin/bats)

.PHONY: ayuda lint comprobar-bats test test-real herramientas limpiar

ayuda:
	@echo "Objetivos disponibles:"
	@echo "  make lint          ShellCheck sobre bin/, lib/ y tests/"
	@echo "  make test          pruebas con bats"
	@echo "  make test-real     pruebas + alta real de usuarios (root, entorno desechable)"
	@echo "  make herramientas  instala bats en .tools/ con npm"
	@echo "  make limpiar       borra .tools/"

lint:
	@shellcheck --version | sed -n 2p
	shellcheck --severity=style $(SCRIPTS) $(PRUEBAS)
	@echo "ShellCheck: sin avisos en $(words $(SCRIPTS) $(PRUEBAS)) ficheros."

comprobar-bats:
	@if ! command -v "$(BATS)" > /dev/null 2>&1; then \
	  echo "No se encuentra bats. Instálalo (apt install bats) o ejecuta: make herramientas"; \
	  exit 1; \
	fi

test: comprobar-bats
	$(BATS) tests/

test-real: comprobar-bats
	@echo "AVISO: crea y borra usuarios reales (zzprueba1, zzprueba2). Úsalo solo en un entorno desechable."
	ALTA_PRUEBAS_REALES=1 $(BATS) tests/

herramientas:
	npm install --prefix .tools --no-save --no-package-lock bats

limpiar:
	rm -rf .tools
