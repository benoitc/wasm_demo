QJS_URL = https://github.com/quickjs-ng/quickjs/releases/download/v0.16.2/qjs-wasi.wasm

.PHONY: all priv test shell clean distclean

all: priv
	rebar3 compile

# What fills priv/. The interpreter is somebody else's build and is not in git,
# so a fresh clone has to fetch it once before anything can run QuickJS.
priv: priv/qjs-wasi.wasm

priv/qjs-wasi.wasm:
	curl -fsSLo $@ $(QJS_URL)

test: priv
	rebar3 eunit

shell: priv
	rebar3 shell

clean:
	rebar3 clean

# Also drops the fetched interpreter, which is what to run before changing
# QJS_URL to a different release.
distclean: clean
	rm -f priv/qjs-wasi.wasm
