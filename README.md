# wasm_demo

A small project that uses [erlang_wasm][] 0.9: a module compiled from text, a
host function the guest calls, two language runtimes, QuickJS and CPython, kept
running over stdin and stdout, and a component called with typed values. The
runtime is written in Erlang, so there is no native toolchain to install and
nothing to build beyond `rebar3 compile`.

## Set it up

You need Erlang/OTP 29 (the runtime uses `-nominal` types and triple-quoted
strings), rebar3, and `curl` for one download. No C toolchain and no
WebAssembly toolchain. If a C compiler is present, erlang_wasm builds an
optional NIF for WASI path resolution; without one it uses its Erlang fallback
and says so during the build.

```sh
git clone https://github.com/benoitc/wasm_demo.git
cd wasm_demo
make priv          # downloads the two interpreters, about 26 MB, once
make test          # 5 tests, 0 failures
```

`make priv` is the step that fills `priv/`. You do not have to run it
separately, because `make`, `make test` and `make shell` all depend on it; it
has a name so that the one thing a fresh clone is missing has a command that
gets it.

## Try it

```sh
make shell
```

```erlang
1> wasm_demo:add(3, 4).
7
2> wasm_demo:greet(~"erlang").
<<"hello, erlang!">>
3> J = wasm_demo:js_worker(), wasm_demo:ask(J, #{name => ~"ada"}).
#{<<"name">> => <<"ADA">>}
4> wasm_demo:ask(J, #{x => ~"y", n => 1}).
#{<<"n">> => 1,<<"x">> => <<"Y">>}
5> wasm_demo:stop(J).
{ok,[]}
```

The same worker, in Python. `ask/3` takes a timeout, and the first request needs
one: it is paying for CPython to start.

```erlang
6> P = wasm_demo:py_worker(), wasm_demo:ask(P, #{name => ~"ada"}, 120000).
#{<<"name">> => <<"ADA">>}
7> wasm_demo:ask(P, #{x => ~"y", n => 1}).
#{<<"n">> => 1,<<"x">> => <<"Y">>}
8> wasm_demo:stop(P).
{ok,[]}
```

A component, called with strings, records and lists rather than pointers:

```erlang
9> T = wasm_demo:text([~"the", ~"a"]), wasm_demo:shout(T, ~"hello, component").
{ok,<<"HELLO, COMPONENT!">>}
10> wasm_demo:shout(T, ~"").
{error,<<"nothing to shout">>}
11> H = wasm_demo:tally(T), wasm_demo:count(T, H, ~"the cat saw the dog").
3
12> wasm_demo:count(T, H, ~"a cat, a dog").
3
13> wasm_demo:top(T, H, 2).
[#{<<"n">> => 2,<<"word">> => <<"cat">>},
 #{<<"n">> => 2,<<"word">> => <<"dog">>}]
14> wasm_demo:drop(T, H), wasm_demo:close(T).
ok
```

The first two calls build and run a module inline. The worker calls keep an
interpreter alive between requests, and most of this page is about them. The
last block is a component, and [Components](#components) explains it.

## Why the worker, in one table

`priv/worker.js` and `priv/worker.py` are the same twelve lines in two
languages: read a JSON object per line, uppercase every string, write one back.
Neither knows Erlang exists. What differs is what starting one costs:

| | QuickJS | CPython |
| --- | ---: | ---: |
| the module | 1.5 MB | 25 MB |
| decode and validate | 105 ms | 643 ms |
| instantiate | 93 ms | 554 ms |
| first request | 213 ms | 34,396 ms |
| every request after | 1 to 12 ms | 8 to 88 ms |

CPython takes half a minute to reach its first reply and then answers in tens of
milliseconds, because that first request is CPython itself starting: importing
`encodings` and `site` on an interpreted runtime. **That ratio is the argument
for the worker.** A process per request would pay the half minute every time;
one that stays up pays it once.

Two honest caveats. These are one machine on one afternoon, so read them as
shape and not as numbers you will reproduce. And CPython's first request is
about 34 seconds in a fresh VM but about 14 in a VM that has already run one:
the difference is garbage collection, 20.6 seconds of it across 183 major
collections the first time against 0.9 seconds and a single major after that,
for the same reductions and the same 227 MB peak heap. Whichever number you
get, the shape of the table does not change. Re-run on erlang_wasm
0.9.0, every row is within noise of the one above.

## What is in priv/

| file | in git | what it is |
| --- | --- | --- |
| `worker.js` | yes | the JavaScript guest: one JSON object per line in, one per line out |
| `worker.py` | yes | the same thing in Python |
| `text.component.wasm` | yes | the component, built from `component/` by `make component` |
| `qjs-wasi.wasm` | **no** | the QuickJS interpreter, [released by quickjs-ng][qjs] |
| `python.wasm` | **no** | CPython 3.12 for `wasm32-wasi`, [built by VMware Labs][wlr] |

The two interpreters are somebody else's builds, so they are downloaded rather
than committed and `.gitignore` keeps them out. **A fresh clone does not have
them.** `make priv` fetches both, and `make`, `make test` and `make shell` each
do that first, so the only way to hit the gap is to run `rebar3` directly on a
fresh clone. If you do, the worker says which file is missing:

```erlang
** exception error: {no_guest,".../priv/python.wasm","run `make priv' to fetch it"}
```

Neither is patched or repackaged. `python.wasm` is unmodified upstream CPython
built for `wasm32-wasi`, which is the point: the runtime runs what a toolchain
produced, not something prepared for it.

To pin different builds, change `QJS_URL` or `PY_URL` in the Makefile and run
`make distclean priv`. Nothing else in the project knows the versions.

The scripts are mounted read-only at `/app`, and that is the only path a guest
can see:

```erlang
dirs => [{~"/app", Priv, read}]
```

## There is no async API, and none is missing

`erlang_wasm` has no `call_async`, no `await` and no `interrupt`. That is not an
omission. The runtime is written in Erlang, so `wasm:call/3` runs the
interpreter in *your* process: there is no thread to hand the work to, and an
async call would have to spawn a process and move the instance into it, which
is a worker you can write yourself and tune to your own timeout and restart
policy.

| what you want | what you use |
| --- | --- |
| start work without blocking | `spawn_link/1` a process that owns the instance |
| a deadline | `receive ... after`, then `exit(Pid, kill)` |
| cancel a runaway guest | `exit(Pid, kill)`; the instance goes with the process |
| feed a guest that is still running | a `stdin` fun that blocks in a `receive` |
| read output as it is produced | a `stdout` pid, or a fun to join partial writes |
| more throughput | more workers, never two callers into one instance |

`js_worker/0` and `py_worker/0` are all six of those, and they differ only in
which interpreter is loaded and which script it is told to run. `_start` runs
inline on a process of its own, and the guest blocks inside `fd_read` because
the `stdin` capability it was granted is a function that blocks:

```erlang
Wasi = #{args   => [~"qjs", ~"/app/worker.js"],
         dirs   => [{~"/app", Priv, read}],
         stdin  => fun(_Want) -> next_request() end,
         stdout => fun(Data) -> collect_line(Owner, Data) end},
{ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi)).

next_request() ->
    receive
        {req, From, Data} -> put(asker, From), {ok, iolist_to_binary(Data)};
        {stop, From}      -> From ! {stopped, self(), {ok, []}}, eof
    end.
```

`{ok, Bytes}` satisfies one read. `eof` ends the guest's read loop, which is how
`_start` returns and the worker finishes, so stopping it in the ordinary case is
a message rather than a kill.

Two things that owes you, and `ask/2,3` pays both: the reply comes back through
your own mailbox under a timeout you choose, and the framing is yours, one JSON
object per line, because stdin is a byte stream and nothing in it marks where a
message ends. The timeout being yours is why `ask/3` exists: five seconds is
generous for QuickJS and not nearly enough for CPython's first request. The one
thing it does not do is bound a guest that stops reading, which is what
`exit(Pid, kill)` is for.

Backpressure is the mailbox. [Streams][streams] and [Workers][workers] in the
erlang_wasm guides have the general version of both.

## Components

A core module speaks in integers and a memory you write into, which is why
`greet/1` copies a name into memory and reads the reply back by offset. A
component declares its interface in WIT, and erlang_wasm marshals values across
it through the Canonical ABI. `priv/text.component.wasm` is built from
`component/`, and its interface is the whole contract:

```wit
interface host {
  stop-word: func(word: string) -> bool;
}

interface words {
  record count { word: string, n: u32 }
  shout: func(input: string) -> result<string, string>;
  resource tally {
    constructor();
    add: func(text: string) -> u32;
    top: func(n: u32) -> list<count>;
  }
}

world text {
  import host;
  export words;
}
```

### Call an export

You name the export and give its WIT signature as descriptors. Exports of an
interface are named `<interface>#<function>`:

```erlang
Sig = {[string], {result, string, string}},
{ok, {ok, Loud}} = wasm_component:call(T, ~"demo:text/words#shout", Sig, [~"hi"]).
```

A `result` comes back as `{ok, V}` or `{error, E}`, so a refusal from the guest
is a value you match on, not a trap. A `record` is a map, a `list` is a list.

### Answer an import

The component imports `stop-word`, and the Erlang list you pass to `text/1`
answers it. `import_fun/2` lifts the guest's arguments to terms and lowers your
return value back:

```erlang
StopWord = wasm_component:import_fun({[string], bool},
                                     fun([W]) -> lists:member(W, StopWords) end),
{ok, T} = wasm_component:instantiate(Bin, #{{~"demo:text/host", ~"stop-word"} => StopWord}).
```

Every word the tally counts goes through that fun first, which is why "the" and
"a" never show up in `top/3`.

### Hold a resource

`tally` is state the component owns. The constructor gives you a handle; you
pass it back to each method as a `borrow` and give it up with
`drop_resource/3`, which runs the guest's destructor:

```erlang
{ok, H} = wasm_component:call(T, ~"demo:text/words#[constructor]tally", {[], {own, 0}}, []),
{ok, N} = wasm_component:call(T, ~"demo:text/words#[method]tally.add",
                              {[{borrow, 0}, string], u32}, [H, ~"the cat"]),
ok = wasm_component:drop_resource(T, ~"demo:text/words#[dtor]tally", H).
```

Notes:

- Components need the `wasm` application running. `rebar3 shell` starts it
  because `rebar.config` lists the app under `shell`; a test or an escript
  calls `application:ensure_all_started(wasm)`.
- The instance belongs to the process that created it. Call it and destroy it
  from there, or put it behind a worker the way `js_worker/0` does.
- Do not use a handle after you drop it. For a handle you hold, erlang_wasm
  0.9 returns whatever the freed memory now says rather than trapping.
- The built component is in git, so you need no toolchain to run it. To change
  it, edit `component/` and run `make component`, which needs Rust with the
  `wasm32-unknown-unknown` target and `wasm-tools`.

[Components][components] in the erlang_wasm guides has the full descriptor
table, composed components and WASI 0.2.

## Capabilities

Nothing is ambient: leave `dirs` out and the guest has no filesystem, leave
`net` out and it has no network. It gets what you granted and nothing else.

## License

Apache-2.0. See [LICENSE](LICENSE).

[erlang_wasm]: https://github.com/benoitc/erlang_wasm
[qjs]: https://github.com/quickjs-ng/quickjs/releases
[wlr]: https://github.com/vmware-labs/webassembly-language-runtimes/releases
[streams]: https://github.com/benoitc/erlang_wasm/blob/main/docs/streams.md
[workers]: https://github.com/benoitc/erlang_wasm/blob/main/docs/worker.md
[components]: https://github.com/benoitc/erlang_wasm/blob/main/docs/components.md
