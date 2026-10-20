NVIM ?= nvim
FILE ?=

.PHONY: test deps lint format docs clean

test: deps
	$(NVIM) --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run($(if $(FILE),{ collect = { find_files = function() return { '$(FILE)' } end } },))" \
		-c "qa!"

deps: deps/mini.nvim

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none --depth 1 https://github.com/echasnovski/mini.nvim $@

lint:
	stylua --check lua plugin tests scripts

format:
	stylua lua plugin tests scripts

clean:
	rm -rf deps .tests
