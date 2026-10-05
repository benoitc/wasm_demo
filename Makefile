QJS_URL = https://github.com/quickjs-ng/quickjs/releases/download/v0.16.2/qjs-wasi.wasm
PY_URL = https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python/3.12.0%2B20231211-040d5a6/python-3.12.0.wasm

.PHONY: all priv component test shell clean distclean

all: priv
	rebar3 compile

# What fills priv/. Both interpreters are somebody else's build and neither is
# in git, so a fresh clone has to fetch them once. About 26 MB in total, nearly
# all of it CPython.
priv: priv/qjs-wasi.wasm priv/python.wasm

priv/qjs-wasi.wasm:
	curl -fsSLo $@ $(QJS_URL)

priv/python.wasm:
	curl -fsSLo $@ $(PY_URL)

# Rebuilds priv/text.component.wasm from component/. Not a dependency of
# anything: the built component is in git, so you need Rust, the
# wasm32-unknown-unknown target and wasm-tools only to change it.
component:
	cd component && cargo build --release --target wasm32-unknown-unknown
	wasm-tools component new \
	    component/target/wasm32-unknown-unknown/release/text.wasm \
	    -o priv/text.component.wasm
	wasm-tools validate --features component-model priv/text.component.wasm

test: priv
	rebar3 eunit

shell: priv
	rebar3 shell

clean:
	rebar3 clean

# Also drops the fetched interpreters, which is what to run before changing
# QJS_URL or PY_URL to a different release.
distclean: clean
	rm -f priv/qjs-wasi.wasm priv/python.wasm
