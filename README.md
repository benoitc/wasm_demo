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

## The worker is a process, not an async call

There is no `call_async` here and none is needed. `_start` runs inline on a
process of its own, and the guest blocks inside `fd_read` because the `stdin`
capability it was granted is a function that blocks:

```erlang
Wasi = #{args   => [~"qjs", ~"/app/worker.js"],
         dirs   => [{~"/app", Priv, read}],
         stdin  => fun(_Want) -> next_request() end,
         stdout => fun(Data) -> collect_line(Owner, Data) end},
{ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi)).
```

Backpressure is the mailbox, a timeout is `receive ... after`, and stopping a
runaway script is killing the process.

Nothing is ambient: leave `dirs` out and the guest has no filesystem, leave
`net` out and it has no network. It gets what you granted and nothing else.

## License

Apache-2.0. See [LICENSE](LICENSE).

[erlang_wasm]: https://github.com/benoitc/erlang_wasm
