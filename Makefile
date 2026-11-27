# Lineage24-for-x64 — automação do pipeline
#
# `make` sem argumento mostra a ajuda. Os scripts carregam config.env, então
# variáveis como ANDROID_DIR/EROFS_BIN podem ser definidas lá.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ifeq ($(shell id -u),0)
SUDO :=
else
SUDO ?= sudo
endif

PROFILE ?= gapps
VARIANT ?= ksu
RELEASE ?=
ISO ?= $(shell find dist -maxdepth 1 -name 'lineage-24.0-*.iso' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
UPLOAD ?= 0
TAG ?=
JOBS ?=
ALLOW_GAPPS ?= 0
WITH_RELEASE ?= 0

RELEASE_ARG := $(if $(RELEASE),--release $(RELEASE),)
ISO_ARG := $(if $(ISO),--iso $(ISO),)
UPLOAD_ARG := $(if $(filter 1 yes true,$(UPLOAD)),--upload,)
TAG_ARG := $(if $(TAG),--tag $(TAG),)
JOBS_ENV := $(if $(JOBS),JOBS=$(JOBS),)
ALLOW_GAPPS_ARG := $(if $(filter 1 yes true,$(ALLOW_GAPPS)),--allow-gapps,)
BOOTSTRAP_RELEASE_ARG := $(if $(filter 1 yes true,$(WITH_RELEASE)),--with-release,)
VENDOR_ARGS = $(if $(filter gapps all,$(PROFILE)),--all,--hwc --ucm --vulkan)

.PHONY: help bootstrap check fetch fetch-kernel kernel vendor install apply-boot gapps iso iso-gapps test-qemu release sources-check clean distclean all

help: ## Mostra esta ajuda
	@printf 'Lineage24-for-x64\n\n'
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nVariáveis: PROFILE=%s VARIANT=%s RELEASE=%s\n' '$(PROFILE)' '$(VARIANT)' '$(if $(RELEASE),$(RELEASE),padrão do lock)'

bootstrap: ## Instala dependências; WITH_RELEASE=1 inclui gh para publicar
	$(SUDO) scripts/bootstrap.sh --install --with-test $(BOOTSTRAP_RELEASE_ARG)

check: ## bash -n + shellcheck + testes Python
	tests/run.sh

fetch: ## Baixa ISO + gbOS + GApps (PROFILE=vanilla|gapps|github-gapps|all)
	scripts/fetch_sources.sh --profile $(PROFILE) $(RELEASE_ARG)

fetch-kernel: fetch ## Baixa ISO base e clona kernel android-mainline + KernelSU pinados
	scripts/fetch_kernel.sh

kernel: fetch-kernel ## Compila kernel 7.2.0+ com KernelSU
	$(JOBS_ENV) scripts/build_kernel_ksu.sh

vendor: fetch ## Extrai e repatcha vendor.img (HWC + UCM + Vulkan; BT no perfil gapps)
	$(SUDO) scripts/build_vendor.sh $(VENDOR_ARGS)

install: kernel ## Prepara artefatos .ksu no workspace; não altera GRUB
	$(SUDO) scripts/install_kernel_ksu.sh

apply-boot: ## Atualiza a entrada GRUB após validar a ISO no QEMU
	$(SUDO) scripts/install_kernel_ksu.sh --apply-boot

gapps: override PROFILE := gapps
gapps: fetch ## Gera system-gapps.img a partir do gbOS86
	$(SUDO) scripts/inject_gapps.sh

iso: install vendor ## Gera a ISO na variante escolhida em VARIANT
	$(SUDO) scripts/make_iso.sh --variant $(VARIANT)

iso-gapps: override PROFILE := gapps
iso-gapps: gapps install vendor ## Gera a ISO KernelSU + Vulkan + GApps
	$(SUDO) scripts/make_iso.sh --variant gapps

test-qemu: ## Boota a ISO no QEMU e checa a matriz de regressão
	scripts/test_qemu.sh $(ISO_ARG) $(if $(filter gapps,$(VARIANT)),--gapps,)

release: ## Prepara assets (partes + sha256); UPLOAD=1 publica com gh
	scripts/release_iso.sh $(ISO_ARG) $(TAG_ARG) $(UPLOAD_ARG) $(ALLOW_GAPPS_ARG)

sources-check: ## Audita os pins e baixa somente o que falta (dry-run)
	scripts/fetch_sources.sh --profile $(PROFILE) $(RELEASE_ARG) --dry-run

all: fetch kernel vendor install iso ## Pipeline completo até criar a ISO (sem atualizar GRUB)

clean: ## Remove artefatos gerados em dist/ e logs/
	rm -rf dist logs tests/__pycache__ scripts/lib/__pycache__
	@echo 'dist/, logs/ e caches Python removidos.'

distclean: ## Remove também cache/, workspace/ e backups/ (IRREVERSÍVEL)
	@printf 'Isso apaga cache/, workspace/, backups/, dist/ e logs/. Confirmar? [s/N] '
	@read -r a; case "$$a" in s|S|y|Y|sim|yes) ;; *) echo 'cancelado'; exit 0 ;; esac
	rm -rf cache workspace backups dist logs
	@echo 'workspace e cache removidos.'
