NAME      := pdfmd
BUILD_DIR := .build/release
PREFIX    ?= $(HOME)/usr

build:
	swift build -c release

test:
	swift test

install: build
	mkdir -p $(PREFIX)/bin
	cp $(BUILD_DIR)/$(NAME) $(PREFIX)/bin/$(NAME)
	cp $(BUILD_DIR)/pdfmd-bench $(PREFIX)/bin/pdfmd-bench

bench-ai2027:
	swift run -c release pdfmd-bench ai2027

.PHONY: build test install bench-ai2027
