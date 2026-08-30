SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables

# ── Project ──────────────────────────────────────────────────────────────────
PROJECT_DIR  := GrasshopperSwift
PROJECT      := $(PROJECT_DIR)/GrasshopperSwift.xcodeproj
PROJECT_SPEC := $(PROJECT_DIR)/project.yml
SCHEME       := GrasshopperSwift
CONFIG       ?= Debug
ARCH         ?= $(shell uname -m)
DESTINATION  ?= platform=macOS,arch=$(ARCH)

# ── Paths ────────────────────────────────────────────────────────────────────
BUILD_ROOT       := $(CURDIR)/.build
DERIVED_DATA_DIR := $(BUILD_ROOT)/DerivedData
PRODUCTS_DIR     := $(BUILD_ROOT)/Products
DIST_DIR         := $(BUILD_ROOT)/dist
APP              := $(PRODUCTS_DIR)/$(CONFIG)/$(SCHEME).app

# ── Tool detection ───────────────────────────────────────────────────────────
XCODEGEN := $(shell command -v xcodegen 2>/dev/null)
XCODEBUILD := $(shell command -v xcodebuild 2>/dev/null)

# ══════════════════════════════════════════════════════════════════════════════
# Public targets
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: help clean rebuild build package run materials

help: ## Show this help
	@printf '\n\033[1;36m── GrasshopperSwift Build ──\033[0m\n\n'
	@printf '\033[1mTargets:\033[0m\n'
	@printf '  \033[33mmake rebuild\033[0m          Clean everything → fresh .app\n'
	@printf '  \033[33mmake package\033[0m          Rebuild from scratch → zip the .app\n'
	@printf '  \033[33mmake run\033[0m              Rebuild from scratch → launch\n'
	@printf '  \033[33mmake clean\033[0m            Remove ALL build artifacts & caches\n'
	@printf '  \033[33mmake project\033[0m          Regenerate Xcode project only\n'
	@printf '  \033[33mmake build\033[0m            Build only (assumes existing project)\n'
	@printf '\n\033[1mVariables:\033[0m\n'
	@printf '  \033[33mCONFIG=Debug|Release\033[0m  (default: Debug)\n'
	@printf '  \033[33mARCH=arm64|x86_64\033[0m    (default: $(ARCH))\n'
	@printf '\n'

# ══════════════════════════════════════════════════════════════════════════════
# rebuild — THE canonical target. Always produces a fresh .app from source.
# ══════════════════════════════════════════════════════════════════════════════

rebuild: clean project build
	@printf '\n\033[1;32m✓  Rebuild complete\033[0m — app is at \033[36m%s\033[0m\n\n' "$(APP)"
	@test -d "$(APP)" || { printf '\033[1;31m✗  FATAL: .app bundle not found after successful build!\033[0m\n'; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# package — rebuild from scratch then zip. Never reuses old binaries.
# ══════════════════════════════════════════════════════════════════════════════

package: clean
	@printf '\n\033[1;36m══════════════════════════════════════════\033[0m\n'
	@printf '\033[1;36m  FRESH BUILD → PACKAGE\033[0m\n'
	@printf '\033[1;36m══════════════════════════════════════════\033[0m\n\n'
	@$(MAKE) project
	@$(MAKE) build
	@printf '\n\033[1;36m── Packaging ──\033[0m\n'
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)"
	@ditto -c -k --keepParent "$(APP)" "$(DIST_DIR)/$(SCHEME)-$(CONFIG).zip"
	@printf '\n\033[1;32m✓  Package complete\033[0m → \033[36m%s\033[0m\n\n' "$(DIST_DIR)/$(SCHEME)-$(CONFIG).zip"

# ══════════════════════════════════════════════════════════════════════════════
# run — rebuild from scratch then launch. Never reuses old binaries.
# ══════════════════════════════════════════════════════════════════════════════

run: clean
	@printf '\n\033[1;36m══════════════════════════════════════════\033[0m\n'
	@printf '\033[1;36m  FRESH BUILD → RUN\033[0m\n'
	@printf '\033[1;36m══════════════════════════════════════════\033[0m\n\n'
	@$(MAKE) project
	@$(MAKE) build
	@printf '\n\033[1;32m✓  Launching app…\033[0m\n\n'
	@open "$(APP)"

# ══════════════════════════════════════════════════════════════════════════════
# clean — nuke every build artifact, cache, and stale product
# ══════════════════════════════════════════════════════════════════════════════

clean: ## Remove ALL build artifacts, caches, and stale products
	@printf '\n\033[1;33m── Cleaning all build artifacts ──\033[0m\n'
	@rm -rf "$(BUILD_ROOT)" \
		&& printf '  \033[90m✓\033[0m removed $(BUILD_ROOT)\n' \
		|| true
	@rm -rf "$(PROJECT_DIR)/DerivedData" \
		&& printf '  \033[90m✓\033[0m removed $(PROJECT_DIR)/DerivedData\n' \
		|| true
	@rm -rf "$(PROJECT_DIR)/.deriveddata" \
		&& printf '  \033[90m✓\033[0m removed $(PROJECT_DIR)/.deriveddata\n' \
		|| true
	@find "$(PROJECT_DIR)" -maxdepth 2 -type d -name '*.app' -exec rm -rf {} + 2>/dev/null; \
		printf '  \033[90m✓\033[0m purged .app bundles in project tree\n' \
		|| true
	@find "$(CURDIR)" -maxdepth 1 -type d -name '*.app' -exec rm -rf {} + 2>/dev/null; \
		printf '  \033[90m✓\033[0m purged .app bundles at project root\n' \
		|| true
	@rm -rf "$(PROJECT_DIR)/xcuserdata" \
		&& printf '  \033[90m✓\033[0m removed xcuserdata\n' \
		|| true
	@rm -rf ~/Library/Developer/Xcode/DerivedData/GrasshopperSwift-* 2>/dev/null; \
		printf '  \033[90m✓\033[0m purged Xcode shared DerivedData\n' \
		|| true
	@printf '\033[1;32m✓  Clean complete — no build artifacts remain\033[0m\n\n'

# ══════════════════════════════════════════════════════════════════════════════
# project — regenerate the Xcode project from project.yml
# ══════════════════════════════════════════════════════════════════════════════

project: ## Regenerate Xcode project via XcodeGen
	@printf '\n\033[1;36m── Generating Xcode project ──\033[0m\n'
ifdef XCODEGEN
	@printf '  Using xcodegen: %s\n' "$(XCODEGEN)"
	@"$(XCODEGEN)" generate --spec "$(PROJECT_SPEC)" --project "$(PROJECT_DIR)" --use-cache
	@printf '\033[1;32m✓  Project generated\033[0m\n'
else
	@printf '\033[1;31m✗  ERROR: xcodegen not found\033[0m\n'
	@printf '  Install with: \033[33mbrew install xcodegen\033[0m\n'
	@exit 1
endif

# ══════════════════════════════════════════════════════════════════════════════
# materials — recompile Filament .mat sources into embedded .filamat headers
# ══════════════════════════════════════════════════════════════════════════════

FILAMENT_DIR := $(PROJECT_DIR)/GrasshopperSwift/Filament

materials: ## Recompile .mat sources into checked-in *_filamat.h headers
	@printf '\n\033[1;36m── Compiling Filament materials ──\033[0m\n'
	@python3 "$(FILAMENT_DIR)/gen_filamat_header.py" studio_pbr \
		"$(FILAMENT_DIR)/studio_pbr.mat" "$(FILAMENT_DIR)/studio_pbr_filamat.h"
	@python3 "$(FILAMENT_DIR)/gen_filamat_header.py" studio_subsurface \
		"$(FILAMENT_DIR)/studio_subsurface.mat" "$(FILAMENT_DIR)/studio_subsurface_filamat.h"
	@printf '\033[1;32m✓  Materials compiled\033[0m\n'

# ══════════════════════════════════════════════════════════════════════════════
# build — compile only (assumes clean tree + generated project)
# ══════════════════════════════════════════════════════════════════════════════

build: ## Build the app (assumes project is already generated)
	@printf '\n\033[1;36m── Building $(SCHEME) ($(CONFIG)) for $(ARCH) ──\033[0m\n'
ifndef XCODEBUILD
	@printf '\033[1;31m✗  ERROR: xcodebuild not found\033[0m\n'
	@exit 1
endif
	@printf '  Destination: $(DESTINATION)\n'
	@printf '  DerivedData: $(DERIVED_DATA_DIR)\n'
	@printf '  Products:    $(PRODUCTS_DIR)\n\n'
	@"$(XCODEBUILD)" \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIG)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA_DIR)" \
		SYMROOT="$(PRODUCTS_DIR)" \
		build
	@printf '\n\033[1;32m✓  Build succeeded\033[0m\n'
	@printf '  App: \033[36m%s\033[0m\n' "$(APP)"
