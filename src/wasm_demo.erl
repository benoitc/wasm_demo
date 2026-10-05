%% Four things a project does with erlang_wasm: call a module, let it call
%% back into Erlang, keep an interpreter running as a worker, and call a
%% component through typed values instead of bare numbers.
-module(wasm_demo).

-export([add/2, greet/1, js_worker/0, py_worker/0, ask/2, ask/3, stop/1]).
-export([text/1, shout/2, tally/1, count/3, top/3, drop/2, close/1]).

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
%% The first request pays for CPython starting: about 34 seconds here, against
%% 8 to 88 milliseconds for the ones after it. That ratio is the argument for
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

%% A component, built from component/ and committed as
%% priv/text.component.wasm. Its interface is in component/wit/text.wit: it
%% exports `shout` and a `tally` resource, and imports `stop-word`, which
%% Erlang answers. Strings, records, lists and results cross the boundary as
%% Erlang terms; nobody writes a pointer.
%%
%% The instance belongs to the process that calls `text/1`: call it and
%% `close/1` it from there.
text(StopWords) ->
    Bin = guest(code:priv_dir(wasm_demo), "text.component.wasm"),
    StopWord = wasm_component:import_fun({[string], bool},
                                         fun([W]) -> lists:member(W, StopWords) end),
    {ok, T} = wasm_component:instantiate(Bin, #{{~"demo:text/host", ~"stop-word"} => StopWord}),
    T.

%% `result<string, string>` comes back as `{ok, _}` or `{error, _}`: an empty
%% phrase is refused by the guest as a value, not a trap.
shout(T, Phrase) ->
    {ok, R} = wasm_component:call(T, words(~"shout"), {[string], {result, string, string}}, [Phrase]),
    R.

%% A tally lives in the component. What you hold is a handle to it, which you
%% pass back to every method and give up with `drop/2`. Do not use a handle
%% after dropping it: it names memory the guest has freed.
tally(T) ->
    {ok, H} = wasm_component:call(T, words(~"[constructor]tally"), {[], {own, 0}}, []),
    H.

%% Each word the guest meets goes through `stop-word` above before it counts.
%% Returns how many distinct words the tally holds.
count(T, H, Text) ->
    {ok, N} = wasm_component:call(T, words(~"[method]tally.add"), {[{borrow, 0}, string], u32}, [H, Text]),
    N.

%% `list<count>`, where `count` is a record, comes back as a list of maps.
top(T, H, N) ->
    Count = {record, [{~"word", string}, {~"n", u32}]},
    {ok, L} = wasm_component:call(T, words(~"[method]tally.top"), {[{borrow, 0}, u32], {list, Count}}, [H, N]),
    L.

drop(T, H) -> wasm_component:drop_resource(T, words(~"[dtor]tally"), H).

close(T) -> wasm_component:destroy(T).

%%% ------------------------------------------------------------- internals ---

%% Exports of an interface are named `<interface>#<function>`.
words(Name) -> <<"demo:text/words#", Name/binary>>.

%% An interpreter is somebody else's build and is not in git, so a fresh clone
%% does not have one until the Makefile fetches it. Say that, rather than
%% failing on a badmatch that names neither the file nor the fix. The
%% component is in git, so it is never the one missing.
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
