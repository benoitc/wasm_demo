-module(checkout_rules).
-moduledoc """
The registry of merchants' rules, and the only process that changes them.

For each merchant it keeps the versions of its rule (the JavaScript source),
which one is active, and the previous one, for `rollback/1` and for the
circuit breaker. Readers never wait on this server: the active rule, the
runtimes and the counters are in ETS.

Changing a rule never restarts a runtime. `upload/2` first runs the new
source in a separate **validation runtime**, on the sample carts below, so a
rule that does not compile, throws, loops or answers out of bounds is refused
before it reaches a merchant's runtimes. Then it is defined in every runtime
of the merchant, and activated in every one: compiled first, switched after.

The **circuit breaker**: after `?TRIP` failed checkouts in a row, the
merchant goes back to its previous version, or to no rule, and `status/0`
says why. `checkout` records each outcome with `record/2`.

`checkout` is the API you call; `checkout_runtime` is one runtime.
""".
-behaviour(gen_server).

-export([start_link/0, upload/2, try_rule/2, rollback/1, status/0]).
-export([register_runtime/3, active/1, runtimes/1, pick/1, record/2,
         check_result/2, sample_carts/0, deadline/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(MERCHANTS, checkout_merchants).
-define(RUNTIMES, checkout_runtimes).
-define(COUNTERS, checkout_counters).
-define(VALIDATION, '$validation').

%% A checkout's deadline, in milliseconds. About six times what a rule takes
%% once its runtime is warm, and room for the first call after a restart.
-define(DEADLINE, 100).
%% How long a change of rule may wait on one runtime.
-define(CONTROL_TIMEOUT, 2000).
%% Failed checkouts in a row before the breaker trips.
-define(TRIP, 5).
%% Runtimes per merchant.
-define(POOL, 2).
%% Discounts a rule may return for one checkout.
-define(MAX_DISCOUNTS, 5).

%%% ------------------------------------------------------------------ api ---

-doc false.
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc """
Check `Source` in the validation runtime, then make it `Merchant`'s active
rule, live, in every runtime the merchant has.

Answers `{ok, Version}`, or `{error, Why}` with what failed and on which
sample cart: `{does_not_compile, Msg}`, `{throws, Msg, Cart}`,
`{timeout, Cart}` or `{bad_result, Why, Cart}`.
""".
-spec upload(atom(), binary()) -> {ok, pos_integer()} | {error, term()}.
upload(Merchant, Source) when is_atom(Merchant), is_binary(Source) ->
    gen_server:call(?SERVER, {upload, Merchant, Source}, 30000).

-doc """
Run `Source` on `Cart` in the validation runtime, without activating it.

Answers `{ok, Discounts, Logs}` or `{error, Why, Logs}`, where `Logs` is
what the rule printed with `console.log`.
""".
-spec try_rule(binary(), map()) ->
          {ok, list(), [binary()]} | {error, term(), [binary()]}.
try_rule(Source, Cart) ->
    gen_server:call(?SERVER, {try_rule, Source, Cart}, 30000).

-doc "Switch `Merchant` back to its previous version.".
-spec rollback(atom()) -> {ok, pos_integer()} | {error, no_previous}.
rollback(Merchant) -> gen_server:call(?SERVER, {rollback, Merchant}, 30000).

-doc "One map per merchant: versions, the active one, the breaker, counts.".
-spec status() -> [map()].
status() ->
    [status_of(M, R) || {M, R} <- lists:sort(ets:tab2list(?MERCHANTS))].

-doc false.
register_runtime(Merchant, Index, Pid) ->
    ets:insert(?RUNTIMES, {{Merchant, Index}, Pid}).

-doc "The active version and its source, or `none`.".
-spec active(atom()) -> {pos_integer(), binary()} | none.
active(Merchant) ->
    case ets:lookup(?MERCHANTS, Merchant) of
        [{_, #{active := V, versions := Vs}}] when V =/= none ->
            {V, maps:get(V, Vs)};
        _ ->
            none
    end.

-doc "The merchant's runtimes that are alive.".
-spec runtimes(atom()) -> [pid()].
runtimes(Merchant) ->
    [P || [P] <- ets:match(?RUNTIMES, {{Merchant, '_'}, '$1'}),
          is_process_alive(P)].

-doc "One of the merchant's runtimes, in turn, or `none`.".
-spec pick(atom()) -> pid() | none.
pick(Merchant) ->
    case runtimes(Merchant) of
        [] -> none;
        Pids ->
            N = ets:update_counter(?COUNTERS, {rr, Merchant}, 1,
                                   {{rr, Merchant}, 0}),
            lists:nth(N rem length(Pids) + 1, Pids)
    end.

-doc """
Count a checkout's outcome, and trip the breaker on the `?TRIP`th failure of
the rule in a row: a timeout, a throw or an answer out of bounds. A checkout
that found no runtime, because the merchant's were being restarted, is
counted but is not the rule's failure.
""".
-spec record(atom(), {ok, list()} | {fallback, term()}) -> ok.
record(Merchant, Outcome) ->
    Kind = kind(Outcome),
    _ = ets:update_counter(?COUNTERS, {Merchant, Kind}, 1,
                           {{Merchant, Kind}, 0}),
    case Kind of
        ok ->
            ets:insert(?COUNTERS, {{streak, Merchant}, 0});
        _ when Kind =:= no_rule; Kind =:= no_runtime;
               Kind =:= runtime_restarted ->
            ok;
        _ ->
            case ets:update_counter(?COUNTERS, {streak, Merchant}, 1,
                                    {{streak, Merchant}, 0}) of
                ?TRIP -> gen_server:cast(?SERVER, {trip, Merchant, Outcome});
                _ -> ok
            end
    end,
    ok.

-doc """
Check what a rule answered against the bounds a checkout accepts: a list of
at most `?MAX_DISCOUNTS` maps, each with a `code` and either a `percent`
between 0 and 100 or an `amount` between 0 and the cart's total.
""".
-spec check_result(term(), map()) -> {ok, list()} | {error, term()}.
check_result(R, _Cart) when not is_list(R) -> {error, not_a_list};
check_result(R, _Cart) when length(R) > ?MAX_DISCOUNTS -> {error, too_many};
check_result(R, Cart) ->
    Total = total(Cart),
    case [{D, Why} || D <- R, {error, Why} <- [check_discount(D, Total)]] of
        [] -> {ok, R};
        [{D, Why} | _] -> {error, {bad_discount, D, Why}}
    end.

-doc "The carts every new rule is tried on before it goes live.".
-spec sample_carts() -> [map()].
sample_carts() ->
    [#{items => [#{sku => ~"mug", price => 1500, qty => 1}],
       currency => ~"EUR", customer => #{id => ~"c-1", tier => ~"bronze"}},
     #{items => [#{sku => ~"kettle", price => 8000, qty => 2},
                 #{sku => ~"tea", price => 2500, qty => 2}],
       currency => ~"EUR", customer => #{id => ~"c-2", tier => ~"gold"}},
     #{items => [], currency => ~"EUR",
       customer => #{id => ~"c-3", tier => ~"silver"}}].

-doc "A checkout's deadline, in milliseconds.".
-spec deadline() -> pos_integer().
deadline() -> ?DEADLINE.

%%% ------------------------------------------------------------ callbacks ---

-doc false.
init([]) ->
    ets:new(?MERCHANTS, [named_table, protected, set]),
    ets:new(?RUNTIMES, [named_table, public, set]),
    ets:new(?COUNTERS, [named_table, public, set]),
    %% Loaded by this process, which lives as long as the runtimes do: the
    %% process that loads a module is the one that keeps it loaded.
    {ok, Mod} = wasm:load(wasm_demo:guest(code:priv_dir(wasm_demo),
                                          "qjs-wasi.wasm")),
    persistent_term:put({checkout, qjs}, Mod),
    {ok, #{}}.

-doc false.
handle_call({upload, Merchant, Source}, _From, S) ->
    case validate(Source, sample_carts()) of
        ok -> {reply, {ok, install(Merchant, Source)}, S};
        {error, Why, _Logs} -> {reply, {error, Why}, S}
    end;
handle_call({try_rule, Source, Cart}, _From, S) ->
    {reply, validate(Source, [Cart]), S};
handle_call({rollback, Merchant}, _From, S) ->
    case ets:lookup(?MERCHANTS, Merchant) of
        [{_, #{previous := P} = R}] when P =/= none ->
            switch(Merchant, P),
            put_merchant(Merchant, R#{active := P,
                                      previous := maps:get(active, R)}),
            {reply, {ok, P}, S};
        _ ->
            {reply, {error, no_previous}, S}
    end.

-doc false.
handle_cast({trip, Merchant, Outcome}, S) ->
    [{_, R = #{active := V, previous := P}}] = ets:lookup(?MERCHANTS, Merchant),
    To = case P of none -> null; _ -> P end,
    switch(Merchant, To),
    Active = case To of null -> none; _ -> To end,
    logger:warning("checkout: ~p's rule ~p tripped the breaker (~p); now ~p",
                   [Merchant, V, Outcome, Active]),
    put_merchant(Merchant,
                 R#{active := Active, previous := none,
                    breaker := #{from => V, to => Active,
                                 reason => Outcome,
                                 at => calendar:system_time_to_rfc3339(
                                         erlang:system_time(second))}}),
    ets:insert(?COUNTERS, {{streak, Merchant}, 0}),
    {noreply, S}.

-doc false.
handle_info(_Msg, S) -> {noreply, S}.

%%% ------------------------------------------------------------ internals ---

%% A new version: defined in every runtime first, then activated, so a
%% checkout sees the old rule or the new one and never neither. A merchant
%% seen for the first time gets its pool, which starts with the rule.
install(Merchant, Source) ->
    R0 = case ets:lookup(?MERCHANTS, Merchant) of
             [{_, R}] -> R;
             [] -> #{active => none, previous => none, versions => #{},
                     next => 1, breaker => none}
         end,
    #{next := V, active := Old, versions := Vs} = R0,
    Keep = maps:with([K || K <- [Old], K =/= none], Vs),
    R1 = R0#{versions := Keep#{V => Source}, next := V + 1,
             previous := Old, breaker := none},
    case runtimes(Merchant) of
        [] ->
            put_merchant(Merchant, R1#{active := V}),
            {ok, _} = checkout_sup:start_pool(Merchant, ?POOL);
        _ ->
            put_merchant(Merchant, R1),
            switch(Merchant, V),
            put_merchant(Merchant, R1#{active := V})
    end,
    ets:insert(?COUNTERS, {{streak, Merchant}, 0}),
    V.

switch(Merchant, null) ->
    [control(P, #{op => activate, version => null})
     || P <- runtimes(Merchant)],
    ok;
switch(Merchant, V) ->
    [{_, #{versions := Vs}}] = ets:lookup(?MERCHANTS, Merchant),
    Pids = runtimes(Merchant),
    [control(P, #{op => define, version => V, source => maps:get(V, Vs)})
     || P <- Pids],
    [control(P, #{op => activate, version => V}) || P <- Pids],
    ok.

%% A runtime that died during a change comes back with the active rule from
%% the table, so its answer does not matter here.
control(Pid, Request) ->
    _ = checkout_runtime:call(Pid, Request, ?CONTROL_TIMEOUT),
    ok.

%% Define, activate, then call on each cart, in the validation runtime. A
%% candidate that loops is killed at the deadline, and the validation
%% runtime restarts; no merchant's runtime is involved.
validate(Source, Carts) ->
    Pid = validation_runtime(),
    Tag = erlang:unique_integer([positive]),
    Result =
        case checkout_runtime:call(Pid, #{op => define, version => Tag,
                                          source => Source}, ?CONTROL_TIMEOUT) of
            {ok, #{~"error" := Msg}} ->
                {error, {does_not_compile, Msg}, []};
            {ok, _} ->
                {ok, _} = checkout_runtime:call(
                            Pid, #{op => activate, version => Tag},
                            ?CONTROL_TIMEOUT),
                run_samples(Pid, Carts, []);
            {error, Why} ->
                {error, {does_not_compile, Why}, []}
        end,
    case is_process_alive(Pid) of
        true ->
            _ = checkout_runtime:call(Pid, #{op => activate, version => null},
                                      ?CONTROL_TIMEOUT),
            _ = checkout_runtime:call(Pid, #{op => drop, version => Tag},
                                      ?CONTROL_TIMEOUT);
        false ->
            ok
    end,
    case {Result, Carts} of
        {{ok, [{Discounts, Logs}]}, [_]} -> {ok, Discounts, Logs};
        {{ok, _}, _} -> ok;
        _ -> Result
    end.

run_samples(_Pid, [], Acc) -> {ok, lists:reverse(Acc)};
run_samples(Pid, [Cart | Rest], Acc) ->
    case checkout_runtime:call(Pid, #{op => call, cart => Cart}, ?DEADLINE) of
        {ok, #{~"ok" := R} = A} ->
            case check_result(R, Cart) of
                {ok, D} -> run_samples(Pid, Rest, [{D, logs(A)} | Acc]);
                {error, Why} -> {error, {bad_result, Why, Cart}, logs(A)}
            end;
        {ok, #{~"error" := Msg} = A} ->
            {error, {throws, Msg, Cart}, logs(A)};
        {error, timeout} ->
            {error, {timeout, Cart}, []};
        {error, Why} ->
            {error, {runtime_died, Why, Cart}, []}
    end.

logs(A) -> maps:get(~"logs", A, []).

%% The validation runtime is started on first use, and after a kill its
%% supervisor brings it back; wait for that rather than fail an upload.
validation_runtime() -> validation_runtime(200).

validation_runtime(0) -> error(no_validation_runtime);
validation_runtime(N) ->
    case runtimes(?VALIDATION) of
        [Pid | _] -> Pid;
        [] when N =:= 200 ->
            case ets:lookup(?RUNTIMES, {?VALIDATION, 1}) of
                [] -> {ok, _} = checkout_sup:start_pool(?VALIDATION, 1),
                      validation_runtime(N - 1);
                _ -> timer:sleep(10), validation_runtime(N - 1)
            end;
        [] ->
            timer:sleep(10),
            validation_runtime(N - 1)
    end.

put_merchant(Merchant, R) -> ets:insert(?MERCHANTS, {Merchant, R}).

status_of(M, #{active := A, previous := P, versions := Vs, breaker := B}) ->
    Counts = maps:from_list(
               [{K, N} || [K, N] <- ets:match(?COUNTERS, {{M, '$1'}, '$2'})]),
    #{merchant => M, active => A, previous => P,
      versions => lists:sort(maps:keys(Vs)), breaker => B,
      runtimes => length(runtimes(M)), counts => Counts}.

kind({ok, _}) -> ok;
kind({fallback, no_rule}) -> no_rule;
kind({fallback, {Kind, _}}) -> Kind;
kind({fallback, Kind}) -> Kind.

check_discount(D, Total) when is_map(D) ->
    Code = maps:get(~"code", D, undefined),
    case {is_binary(Code) andalso Code =/= <<>>,
          maps:get(~"percent", D, undefined), maps:get(~"amount", D, undefined)} of
        {false, _, _} -> {error, no_code};
        {true, P, undefined} when is_number(P), P > 0, P =< 100 -> ok;
        {true, undefined, A} when is_integer(A), A > 0, A =< Total -> ok;
        {true, undefined, undefined} -> {error, no_percent_or_amount};
        {true, P, undefined} -> {error, {percent_out_of_bounds, P}};
        {true, undefined, A} -> {error, {amount_out_of_bounds, A}};
        {true, _, _} -> {error, both_percent_and_amount}
    end;
check_discount(_D, _Total) ->
    {error, not_a_map}.

total(Cart) ->
    lists:sum([field(price, I) * field(qty, I) || I <- field(items, Cart)]).

field(K, M) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error -> maps:get(atom_to_binary(K), M)
    end.
