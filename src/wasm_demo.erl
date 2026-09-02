%% Three things a project does with erlang_wasm: call a module, let it call
%% back into Erlang, and keep a JavaScript worker running.
-module(wasm_demo).

-export([add/2, greet/1, js_worker/0, py_worker/0, ask/2, ask/3, stop/1]).

%% A module compiled from text, called like a function.
add(A, B) ->
    {ok, Mod} = wasm:compile({wat, ~"""
    (module
      (func (export "add") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.add))
    """}),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    {ok, [Sum]} = wasm:call(Inst, ~"add", [A, B]),
    ok = wasm:destroy(Inst),
    Sum.

%% The guest calls an import that Erlang provides: it hands a name to
%% `env.greet`, which writes a greeting back into the guest's memory.
greet(Name) when is_binary(Name) ->
    {ok, Mod} = wasm:compile({wat, ~"""
    (module
      (import "env" "greet" (func $greet (param i32 i32) (result i32)))
      (memory (export "memory") 1)
      ;; the name sits at 0; greet returns the length written at 1024
      (func (export "run") (param i32) (result i32)
        (call $greet (i32.const 0) (local.get 0))))
    """}),
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

%% Two workers that answer one JSON line per request, in two languages that
%% know nothing about Erlang. They differ only in which interpreter is loaded
%% and which script it is told to run.
%%
%% There is no async call here and none is wanted: `_start` runs inline on a
%% process of its own, and the guest blocks in `fd_read` because the `stdin`
%% capability is a function that blocks. Backpressure is the mailbox, and
%% killing the process is how you stop a runaway script.
%%
%% Needs priv/qjs-wasi.wasm (see the Makefile).
js_worker() -> worker("qjs-wasi.wasm", [~"qjs", ~"/app/worker.js"], 1024).

%% Needs priv/python.wasm, which `make priv' fetches too.
%%
%% `-u' because CPython buffers stdout in blocks when it is not a terminal, and
%% a reply held in the guest's buffer is a reply that has not arrived.
%%
%% The first request pays for CPython starting: about 33 seconds here, against
%% 11 to 91 milliseconds for the ones after it. That ratio is the argument for
%% the worker. A process per request would pay it every time.
py_worker() -> worker("python.wasm", [~"python", ~"-u", ~"/app/worker.py"], 4096).

worker(File, Args, Pages) ->
    Owner = self(),
    Priv = code:priv_dir(wasm_demo),
    {ok, Mod} = wasm:compile(guest(Priv, File)),
    Pid = spawn_link(fun() -> run_worker(Mod, Args, Pages, Priv, Owner) end),
    #{pid => Pid}.

%% `Timeout' is the caller's, not the guest's: CPython's first request needs
%% far longer than QuickJS's.
ask(W, Term) -> ask(W, Term, 5000).

ask(#{pid := Pid}, Term, Timeout) ->
    Pid ! {req, self(), [json:encode(Term), $\n]},
    receive
        {line, Pid, Line} -> json:decode(string:chomp(Line))
    after Timeout -> error(no_reply)
    end.

stop(#{pid := Pid}) ->
    Pid ! {stop, self()},
    receive {stopped, Pid, R} -> R after 5000 -> error(no_exit) end.

%%% ------------------------------------------------------------- internals ---

%% An interpreter is somebody else's build and is not in git, so a fresh clone
%% does not have one until the Makefile fetches it. Say that, rather than
%% failing on a badmatch that names neither the file nor the fix.
guest(Priv, Name) ->
    File = filename:join(Priv, Name),
    case file:read_file(File) of
        {ok, Bin} -> Bin;
        {error, enoent} -> error({no_guest, File, "run `make priv' to fetch it"});
        {error, Why} -> error({no_guest, File, Why})
    end.

%% One instance per worker, torn down when `_start` returns. `stdout` is a
%% function rather than a pid so the partial writes a guest makes are joined
%% into whole lines here rather than by whoever asked.
run_worker(Mod, Args, Pages, Priv, Owner) ->
    Wasi = #{args => Args,
             dirs => [{~"/app", Priv, read}],
             stdin => fun(_Want) -> next_request() end,
             stdout => fun(Data) -> collect_line(Owner, Data) end,
             stderr => fun(_Data) -> ok end,
             clocks => [monotonic, realtime],
             random => strong},
    {ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi),
                                  #{max_memory_pages => Pages}),
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
