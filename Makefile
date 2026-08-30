QJS_URL = https://github.com/quickjs-ng/quickjs/releases/download/v0.16.2/qjs-wasi.wasm

.PHONY: all test shell clean

all: priv/qjs-wasi.wasm
	rebar3 compile

priv/qjs-wasi.wasm:
	curl -fsSLo $@ $(QJS_URL)

test: priv/qjs-wasi.wasm
	rebar3 eunit

shell: priv/qjs-wasi.wasm
	rebar3 shell

clean:
	rebar3 clean
