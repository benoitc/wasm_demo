# wasm_demo

A small project that uses [erlang_wasm][]: a module compiled from text, a host
function the guest calls, and a QuickJS worker kept running over stdin and
stdout. The runtime is written in Erlang, so there is no native toolchain to
install and nothing to build beyond `rebar3 compile`.

```sh
make test          # fetches qjs-wasi.wasm, builds, runs the eunit tests
make shell
1> wasm_demo:add(3, 4).
7
2> wasm_demo:greet(~"erlang").
<<"hello, erlang!">>
3> W = wasm_demo:js_worker(), wasm_demo:js_ask(W, #{name => ~"ada"}).
#{<<"name">> => <<"ADA">>}
```

## What is in priv/

| file | in git | what it is |
| --- | --- | --- |
| `worker.js` | yes | the guest script: one JSON object per line in, one per line out |
| `qjs-wasi.wasm` | **no** | the QuickJS interpreter, [released by quickjs-ng][qjs] and fetched by the Makefile |

`qjs-wasi.wasm` is somebody else's build, so it is downloaded rather than
committed and `.gitignore` keeps it out. **A fresh clone does not have it**, and
`wasm_demo:js_worker/0` reads it from `code:priv_dir(wasm_demo)` and fails
without it. `make`, `make test` and `make shell` each fetch it first, so use
one of those rather than `rebar3` directly the first time.

To pin a different QuickJS, change `QJS_URL` in the Makefile and delete the
file. Nothing else in the project knows the version.

`worker.js` is mounted read-only at `/app`, and it is the only path the guest
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

`js_worker/0` is all six of those. `_start` runs inline on a process of its
own, and the guest blocks inside `fd_read` because the `stdin` capability it
was granted is a function that blocks:

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

Two things that owes you, and `js_ask/2` pays both: the reply comes back through
your own mailbox under `after 5000`, and the framing is yours, one JSON object
per line, because stdin is a byte stream and nothing in it marks where a message
ends. The one thing it does not do is bound a guest that stops reading, which is
what `exit(Pid, kill)` is for.

Backpressure is the mailbox. [Streams][streams] and [Workers][workers] in the
erlang_wasm guides have the general version of both.

## Capabilities

Nothing is ambient: leave `dirs` out and the guest has no filesystem, leave
`net` out and it has no network. It gets what you granted and nothing else.

## License

Apache-2.0. See [LICENSE](LICENSE).

[erlang_wasm]: https://github.com/benoitc/erlang_wasm
[qjs]: https://github.com/quickjs-ng/quickjs/releases
[streams]: https://github.com/benoitc/erlang_wasm/blob/main/docs/streams.md
[workers]: https://github.com/benoitc/erlang_wasm/blob/main/docs/worker.md
