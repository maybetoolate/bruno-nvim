NVIM ?= nvim

.PHONY: test fmt lint

test:
	$(NVIM) --headless --clean -l tests/run.lua

fmt:
	stylua lua tests plugin

lint:
	stylua --check lua tests plugin
