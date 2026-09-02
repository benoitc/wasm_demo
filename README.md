# wasm_demo

A small project that uses [erlang_wasm][]: a module compiled from text, a host
function the guest calls, and two language runtimes, QuickJS and CPython, kept
running over stdin and stdout. The runtime is written in Erlang, so there is no
native toolchain to install and nothing to build beyond `rebar3 compile`.

## Set it up

You need Erlang/OTP 29 (the runtime uses `-nominal` types and triple-quoted
strings), rebar3, and `curl` for one download. No C toolchain and no
WebAssembly toolchain.

```sh
git clone https://github.com/benoitc/wasm_demo.git
cd wasm_demo
make priv          # downloads the two interpreters, about 26 MB, once
make test          # 4 tests, 0 failures
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

The first two calls build and run a module inline. The rest go through a worker
that keeps an interpreter alive between calls, which is what the rest of this
page is about.

## Why the worker, in one table

`priv/worker.js` and `priv/worker.py` are the same twelve lines in two
languages: read a JSON object per line, uppercase every string, write one back.
Neither knows Erlang exists. What differs is what starting one costs:

| | QuickJS | CPython |
| --- | ---: | ---: |
| the module | 1 MB | 25 MB |
| decode and validate | 30 ms | 769 ms |
| instantiate | 3 ms | 597 ms |
| first request | 250 ms | 32,862 ms |
| every request after | 2 ms | 11 to 91 ms |

CPython takes half a minute to reach its first reply, because `python -c
"print(6*7)"` is 30 seconds of importing `encodings` and `site` on an
interpreted runtime, and then answers in tens of milliseconds. **That ratio is
the argument for the worker.** A process per request would pay the 33 seconds
every time; one that stays up pays it once. Measured on this machine, so treat
them as shape rather than as numbers you will reproduce.

## What is in priv/

| file | in git | what it is |
| --- | --- | --- |
| `worker.js` | yes | the JavaScript guest: one JSON object per line in, one per line out |
| `worker.py` | yes | the same thing in Python |
| `qjs-wasi.wasm` | **no** | the QuickJS interpreter, [released by quickjs-ng][qjs] |
| `python.wasm` | **no** | CPython 3.12 for `wasm32-wasi`, [built by VMware Labs][wlr] |

The two `.wasm` files are somebody else's builds, so they are downloaded rather
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
