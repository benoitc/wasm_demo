QJS_URL = https://github.com/quickjs-ng/quickjs/releases/download/v0.16.2/qjs-wasi.wasm
PY_URL = https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python/3.12.0%2B20231211-040d5a6/python-3.12.0.wasm

.PHONY: all priv component wasi3 actor test shell clean distclean

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

# Rebuilds priv/upper.component.wasm, the WASI 0.3 command, from wasi3/. Like
# the component above it is in git, so you need this only to change it.
wasi3:
	cd wasi3 && cargo build --release --target wasm32-unknown-unknown
	wasm-tools component new \
	    wasi3/target/wasm32-unknown-unknown/release/upper.wasm \
	    -o priv/upper.component.wasm
	wasm-tools validate --features all priv/upper.component.wasm

# Rebuilds priv/counter.component.wasm, the C counter actor, from actor/. The
# built component is in git, so you need this only to change it, and then
# you need wit-bindgen 0.62 (`cargo install wit-bindgen-cli'), WASI SDK 34
# and wasm-tools. The C bindings are generated from actor/wit into
# actor/build and are not committed.
WASI_SDK ?= $(HOME)/.local/opt/wasi-sdk-34.0-arm64-macos
actor:
	mkdir -p actor/build
	wit-bindgen c actor/wit --world counter-actor --out-dir actor/build
	$(WASI_SDK)/bin/clang --target=wasm32-wasip1 -O2 -nostartfiles \
	    -Wl,--no-entry -Wl,--strip-all -Iactor/build \
	    actor/src/counter.c actor/build/counter_actor.c \
	    actor/build/counter_actor_component_type.o \
	    -o actor/build/counter.core.wasm
	wasm-tools component new actor/build/counter.core.wasm \
	    -o priv/counter.component.wasm
	wasm-tools validate --features component-model priv/counter.component.wasm

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
