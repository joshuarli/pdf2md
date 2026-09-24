CARGO     ?= cargo
PREFIX    ?= $(HOME)/usr
TARGET_DIR := target/release

build:
	$(CARGO) build --release

test:
	$(CARGO) test --release

install: build
	mkdir -p $(PREFIX)/bin
	cp $(TARGET_DIR)/pdfmd $(PREFIX)/bin/pdfmd
	cp $(TARGET_DIR)/pdfmd-bench $(PREFIX)/bin/pdfmd-bench

bench-ai2027:
	$(CARGO) run --release --bin pdfmd-bench -- ai2027

.PHONY: build test install bench-ai2027
