PROJECT_DIR := GrasshopperSwift
PROJECT     := $(PROJECT_DIR)/GrasshopperSwift.xcodeproj
PROJECT_SPEC := $(PROJECT_DIR)/project.yml
SCHEME      := GrasshopperSwift
CONFIG      ?= Debug
ARCH        ?= $(shell uname -m)
DESTINATION ?= platform=macOS,arch=$(ARCH)

BUILD_ROOT       := $(CURDIR)/.build
DERIVED_DATA_DIR := $(BUILD_ROOT)/DerivedData
PRODUCTS_DIR     := $(BUILD_ROOT)/Products
DIST_DIR         := $(BUILD_ROOT)/dist
APP              := $(PRODUCTS_DIR)/$(CONFIG)/$(SCHEME).app

.PHONY: help project build run package clean

help:
	@printf "Targets:\n"
	@printf "  make project          Regenerate the Xcode project with XcodeGen\n"
	@printf "  make build            Build $(SCHEME) ($(CONFIG))\n"
	@printf "  make run              Build and launch the app\n"
	@printf "  make package          Build and zip the app under .build/dist\n"
	@printf "  make clean            Remove local build products\n"
	@printf "\nVariables:\n"
	@printf "  CONFIG=Debug|Release  Build configuration, defaults to Debug\n"
	@printf "  ARCH=arm64|x86_64     macOS build architecture, defaults to host arch\n"

project:
	xcodegen generate --spec $(PROJECT_SPEC) --project $(PROJECT_DIR) --use-cache

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA_DIR) \
		SYMROOT=$(PRODUCTS_DIR) \
		build
	@printf "\nBuilt app: $(APP)\n"

run: build
	open $(APP)

package: build
	mkdir -p $(DIST_DIR)
	ditto -c -k --keepParent $(APP) $(DIST_DIR)/$(SCHEME)-$(CONFIG).zip
	@printf "\nPackaged app: $(DIST_DIR)/$(SCHEME)-$(CONFIG).zip\n"

clean:
	rm -rf $(BUILD_ROOT)
