-module(checkout_runtime).
-moduledoc """
One warm JavaScript runtime: a process that owns a QuickJS instance for as
long as it lives.

QuickJS runs `priv/host/rules_host.js`, a loop that reads one JSON request
per line on standard input and answers one per line on standard output. The
instance is started once; rules are added to it while it runs (`define`, then
`activate`), so a checkout calls a function that is already compiled and
nothing starts on the checkout path.

The process spends its life inside `wasm:call(Inst, "_start", [])`: the
guest blocks in `fd_read`, which is the `stdin` fun below waiting in a
`receive`. A request is a message; the answer is sent back by the `stdout`
fun. Nothing else in this module runs while the guest computes.

When a caller's deadline passes, `call/3` kills this process, and the
instance goes with it. The supervisor (`checkout_sup`) starts a fresh one,
which defines the merchant's active rule again before it takes a checkout.

The guest sees one read-only directory holding `rules_host.js` and nothing
else: no other file, no network. `checkout_rules` decides what runs here;
`checkout` is the API you call.
""".

-export([start_link/2, call/3]).
-export([init/3]).

-doc """
Start a runtime for `Merchant`, the `Index`th of its pool, and register it.

Returns once the runtime is warm: QuickJS has started, `rules_host.js` is
running and the merchant's active rule is compiled and active. Only then can
a checkout reach it, so no checkout waits for an engine to start. That takes
about a quarter of a second, more than a checkout's deadline.
""".
-spec start_link(atom(), pos_integer()) -> {ok, pid()}.
start_link(Merchant, Index) ->
    proc_lib:start_link(?MODULE, init, [self(), Merchant, Index]).

-doc """
Send `Request` (a map, encoded as JSON) and wait at most `Timeout` ms.

Answers `{ok, Answer}` with the decoded answer, `{error, timeout}` after
killing the runtime, or `{error, {down, Why}}` if the runtime died while the
request waited.
""".
-spec call(pid(), map(), timeout()) ->
          {ok, map()} | {error, timeout | {down, term()}}.
call(Pid, Request, Timeout) ->
    Ref = monitor(process, Pid),
    Pid ! {line, self(), Ref, [json:encode(Request), $\n]},
    receive
        {answer, Ref, Line} ->
            demonitor(Ref, [flush]),
            {ok, json:decode(Line)};
        {'DOWN', Ref, process, Pid, Why} ->
            {error, {down, Why}}
    after Timeout ->
        exit(Pid, kill),
        demonitor(Ref, [flush]),
        %% An answer sent just before the kill would otherwise stay in the
        %% caller's mailbox for ever.
        receive {answer, Ref, _} -> ok after 0 -> ok end,
        {error, timeout}
    end.

%%% ------------------------------------------------------------ internals ---

init(Parent, Merchant, Index) ->
    Mod = persistent_term:get({checkout, qjs}),
    Host = filename:join(code:priv_dir(wasm_demo), "host"),
    Wasi = #{args => [~"qjs", ~"/app/rules_host.js"],
             dirs => [{~"/app", Host, read}],
             stdin => fun(_Want) -> next_line() end,
             stdout => fun(Data) -> collect(Data) end,
             stderr => fun(_Data) -> ok end,
             clocks => [monotonic, realtime],
             random => strong},
    {ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi),
                                  #{max_memory_pages => 1024}),
    %% The active rule is defined and activated before any request is read,
    %% so a runtime restarted after a timeout comes back with its rule.
    put(boot, boot_lines(checkout_rules:active(Merchant))),
    put(ready, {Parent, Merchant, Index}),
    R = wasm:call(Inst, ~"_start", []),
    exit({runtime_exited, R}).

ready() ->
    case erase(ready) of
        {Parent, Merchant, Index} ->
            checkout_rules:register_runtime(Merchant, Index, self()),
            proc_lib:init_ack(Parent, {ok, self()});
        undefined ->
            ok
    end.

boot_lines(none) -> [];
boot_lines({Version, Source}) ->
    [[json:encode(#{op => define, version => Version, source => Source}), $\n],
     [json:encode(#{op => activate, version => Version}), $\n]].

%% The guest's `fd_read`. Boot lines first, answered to nobody. The first
%% time the guest asks for more, it has started and its rule is active: the
%% runtime registers and tells its starter it is ready. Then one request at a
%% time from the mailbox.
next_line() ->
    case get(boot) of
        [Line | Rest] ->
            put(boot, Rest),
            put(asker, none),
            {ok, iolist_to_binary(Line)};
        _ ->
            ready(),
            receive
                {line, From, Ref, Line} ->
                    put(asker, {From, Ref}),
                    {ok, iolist_to_binary(Line)}
            end
    end.

%% The guest's `fd_write` on stdout. Partial writes are joined into lines; a
%% whole line goes to whoever asked.
collect(Data) ->
    Buf = <<(case get(outbuf) of undefined -> <<>>; B -> B end)/binary,
            (iolist_to_binary(Data))/binary>>,
    put(outbuf, deliver(Buf)),
    ok.

deliver(Buf) ->
    case binary:split(Buf, ~"\n") of
        [Line, Rest] ->
            case get(asker) of
                {From, Ref} -> From ! {answer, Ref, Line};
                _ -> ok
            end,
            put(asker, none),
            deliver(Rest);
        [_] ->
            Buf
    end.
