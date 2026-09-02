QJS_URL = https://github.com/quickjs-ng/quickjs/releases/download/v0.16.2/qjs-wasi.wasm
PY_URL = https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python/3.12.0%2B20231211-040d5a6/python-3.12.0.wasm

.PHONY: all priv test shell clean distclean

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
