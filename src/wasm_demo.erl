%% Three things a project does with erlang_wasm: call a module, let it call
%% back into Erlang, and keep a JavaScript worker running.
-module(wasm_demo).

-export([add/2, greet/1, js_worker/0, js_ask/2, js_stop/1]).

%% A module compiled from text, called like a function.
add(A, B) ->
    {ok, Mod} = wat(~"""
    (module
      (func (export "add") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.add))
    """),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    {ok, [Sum]} = wasm:call(Inst, ~"add", [A, B]),
    ok = wasm:destroy(Inst),
    Sum.

%% The guest calls an import that Erlang provides: it hands a name to
%% `env.greet`, which writes a greeting back into the guest's memory.
greet(Name) when is_binary(Name) ->
    {ok, Mod} = wat(~"""
    (module
      (import "env" "greet" (func $greet (param i32 i32) (result i32)))
      (memory (export "memory") 1)
      ;; the name sits at 0; greet returns the length written at 1024
      (func (export "run") (param i32) (result i32)
        (call $greet (i32.const 0) (local.get 0))))
    """),
    Greet = fun(Ctx, [Ptr, Len]) ->
        {ok, Who} = wasm:read_memory(Ctx, Ptr, Len),
        Reply = <<"hello, ", Who/binary, "!">>,
        ok = wasm:write_memory(Ctx, 1024, Reply),
        {ok, [byte_size(Reply)]}
    end,
    {ok, Inst} = wasm:instantiate(Mod, #{{~"env", ~"greet"} => Greet}),
    ok = wasm:write_memory(Inst, 0, Name),
    {ok, [Len]} = wasm:call(Inst, ~"run", [byte_size(Name)]),
    {ok, Reply} = wasm:read_memory(Inst, 1024, Len),
    ok = wasm:destroy(Inst),
    Reply.

%% A QuickJS worker that answers one JSON line per request.
%%
%% There is no async call here and none is wanted: `_start` runs inline on a
%% process of its own, and the guest blocks in `fd_read` because the `stdin`
%% capability is a function that blocks. Backpressure is the mailbox, and
%% killing the process is how you stop a runaway script.
%%
%% Needs priv/qjs-wasi.wasm (see the Makefile).
js_worker() ->
    Owner = self(),
    Priv = code:priv_dir(wasm_demo),
    {ok, Bin} = file:read_file(filename:join(Priv, "qjs-wasi.wasm")),
    {ok, Mod} = wasm:compile(Bin),
    Pid = spawn_link(fun() -> run_worker(Mod, Priv, Owner) end),
    #{pid => Pid}.

js_ask(#{pid := Pid}, Term) ->
    Pid ! {req, self(), [json:encode(Term), $\n]},
    receive
        {line, Pid, Line} -> json:decode(string:chomp(Line))
    after 5000 -> error(no_reply)
    end.

js_stop(#{pid := Pid}) ->
    Pid ! {stop, self()},
    receive {stopped, Pid, R} -> R after 5000 -> error(no_exit) end.

%%% ------------------------------------------------------------- internals ---

wat(Source) ->
    {ok, Parsed} = wasm_wat:module(Source),
    wasm:validate(Parsed).

%% One instance per worker, torn down when `_start` returns. `stdout` is a
%% function rather than a pid so the partial writes a guest makes are joined
%% into whole lines here rather than by whoever asked.
run_worker(Mod, Priv, Owner) ->
    Wasi = #{args => [~"qjs", ~"/app/worker.js"],
             dirs => [{~"/app", Priv, read}],
             stdin => fun(_Want) -> next_request() end,
             stdout => fun(Data) -> collect_line(Owner, Data) end,
             stderr => fun(_Data) -> ok end,
             clocks => [monotonic, realtime],
             random => strong},
    {ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi),
                                  #{max_memory_pages => 1024}),
    R = wasm:call(Inst, ~"_start", []),
    ok = wasm:destroy(Inst),
    receive {stop, From} -> From ! {stopped, self(), R} after 0 -> ok end.

%% Blocks the guest inside `fd_read` until somebody asks something, which is
%% what makes the worker a worker rather than a batch of input decided up front.
next_request() ->
    receive
        {req, From, Data} -> put(asker, From), {ok, iolist_to_binary(Data)};
        {stop, From} -> From ! {stopped, self(), {ok, []}}, eof
    end.

collect_line(_Owner, Data) ->
    Buf = <<(case get(outbuf) of undefined -> <<>>; B -> B end)/binary,
            (iolist_to_binary(Data))/binary>>,
    case binary:split(Buf, ~"\n") of
        [Line, Rest] ->
            get(asker) ! {line, self(), <<Line/binary, "\n">>},
            put(outbuf, Rest);
        [_] ->
            put(outbuf, Buf)
    end,
    ok.
