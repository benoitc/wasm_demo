-module(checkout).
-moduledoc """
A shop's checkout, where each merchant's discount rule is JavaScript they
wrote, run in a WebAssembly sandbox on every checkout.

This is the API you call from the shell. `docs/checkout.md` walks through it.

- `start/0` and `stop/0` start and stop the service.
- `upload/2` checks a rule and makes it the merchant's active one, live:
  nothing restarts. `rule/1` reads one of the examples in `priv/rules/`.
- `checkout/2` runs a cart through the merchant's rule and always answers:
  the discounts, or a fallback with no discount and the reason.
- `try_rule/2` runs a rule on a cart without activating it, with what it
  printed.
- `rollback/1` goes back to the previous version; `status/0` shows every
  merchant's versions, breaker and counts.
- `load/2` runs checkouts for some merchants for some seconds and prints a
  table of outcomes and latencies.

Each merchant has warm QuickJS runtimes (`checkout_runtime`) that start once
and keep running; `checkout_rules` adds rules to them on the fly.
""".

-export([start/0, stop/0, upload/2, rule/1, try_rule/2, checkout/2, rollback/1,
         status/0, load/2, cart/2]).
-export([checkout_info/2, quiet_kills/2]).

-doc """
Start the service: the `wasm` application, QuickJS compiled once, and the
supervision tree, not linked to the caller, so a crash in the shell does
not stop it.
""".
-spec start() -> ok.
start() ->
    {ok, _} = application:ensure_all_started(wasm_demo),
    _ = logger:add_primary_filter(checkout_kills, {fun ?MODULE:quiet_kills/2, []}),
    {ok, Pid} = checkout_sup:start_link(),
    unlink(Pid),
    ok.

-doc false.
%% A runtime killed at a checkout's deadline is the service working, not a
%% fault, and a looping rule causes one per checkout: its supervisor report
%% is dropped. `status/0` counts them as `timeout`. Every other report passes.
quiet_kills(#{msg := {report, #{label := {supervisor, child_terminated},
                                 report := R}}}, _) ->
    Child = proplists:get_value(offender, R, []),
    case {proplists:get_value(mfargs, Child), proplists:get_value(reason, R)} of
        {{checkout_runtime, start_link, _}, killed} -> stop;
        _ -> ignore
    end;
quiet_kills(_Event, _) ->
    ignore.

-doc "Stop the service and every runtime. Rules are not kept.".
-spec stop() -> ok.
stop() ->
    _ = logger:remove_primary_filter(checkout_kills),
    case whereis(checkout_sup) of
        undefined -> ok;
        Pid ->
            Ref = monitor(process, Pid),
            exit(Pid, shutdown),
            receive {'DOWN', Ref, process, Pid, _} -> ok end
    end.

-doc """
Check `Source` and make it `Merchant`'s active rule.

The rule is first run on three sample carts in a separate runtime. It is
refused if it does not compile, throws, takes longer than the deadline or
answers out of bounds; otherwise it is defined in each of the merchant's
runtimes and switched on, while checkouts go on. Answers `{ok, Version}` or
`{error, Why}`; `docs/checkout.md` lists the reasons.
""".
-spec upload(atom(), binary() | string()) -> {ok, pos_integer()} | {error, term()}.
upload(Merchant, Source) ->
    checkout_rules:upload(Merchant, iolist_to_binary(Source)).

-doc "The source of an example rule in `priv/rules/`, by name: `rule(big_order)`.".
-spec rule(atom()) -> binary().
rule(Name) ->
    File = filename:join([code:priv_dir(wasm_demo), "rules",
                          atom_to_list(Name) ++ ".js"]),
    {ok, Source} = file:read_file(File),
    Source.

-doc """
Run `Source` on `Cart` without activating it anywhere. Answers
`{ok, Discounts, Logs}` or `{error, Why, Logs}`, where `Logs` is what the
rule printed with `console.log`.
""".
-spec try_rule(binary() | string(), map()) ->
          {ok, list(), [binary()]} | {error, term(), [binary()]}.
try_rule(Source, Cart) ->
    checkout_rules:try_rule(iolist_to_binary(Source), Cart).

-doc """
Run `Cart` through `Merchant`'s active rule. Never fails: answers
`{ok, Discounts}`, or `{fallback, Reason}` with no discount when the merchant
has no rule or the rule did not answer in time, threw, or answered out of
bounds.
""".
-spec checkout(atom(), map()) -> {ok, list()} | {fallback, term()}.
checkout(Merchant, Cart) ->
    {Outcome, _Version, _Micros} = checkout_info(Merchant, Cart),
    Outcome.

-doc """
As `checkout/2`, with the version that answered and the time it took, in
microseconds. `load/2` uses it.
""".
-spec checkout_info(atom(), map()) ->
          {{ok, list()} | {fallback, term()}, integer() | none, integer()}.
checkout_info(Merchant, Cart) ->
    T0 = erlang:monotonic_time(microsecond),
    {Outcome, Version} =
        case checkout_rules:pick(Merchant) of
            none ->
                %% No rule at all, or every runtime of the merchant is being
                %% restarted after a timeout.
                case checkout_rules:active(Merchant) of
                    none -> {{fallback, no_rule}, none};
                    _ -> {{fallback, no_runtime}, none}
                end;
            Pid ->
                answer(checkout_runtime:call(
                         Pid, #{op => call, cart => Cart},
                         checkout_rules:deadline()), Cart)
        end,
    checkout_rules:record(Merchant, Outcome),
    {Outcome, Version, erlang:monotonic_time(microsecond) - T0}.

answer({ok, #{~"ok" := R, ~"v" := V}}, Cart) when V =/= null ->
    case checkout_rules:check_result(R, Cart) of
        {ok, D} -> {{ok, D}, V};
        {error, Why} -> {{fallback, {bad_result, Why}}, V}
    end;
answer({ok, #{~"ok" := _, ~"v" := null}}, _Cart) ->
    {{fallback, no_rule}, none};
answer({ok, #{~"error" := Msg, ~"v" := V}}, _Cart) ->
    {{fallback, {throws, Msg}}, V};
answer({error, timeout}, _Cart) ->
    {{fallback, timeout}, none};
answer({error, {down, _}}, _Cart) ->
    {{fallback, runtime_restarted}, none}.

-doc "Switch `Merchant` back to its previous version. Nothing restarts.".
-spec rollback(atom()) -> {ok, pos_integer()} | {error, no_previous}.
rollback(Merchant) -> checkout_rules:rollback(Merchant).

-doc """
Print every merchant's versions, runtimes, counts and breaker.
`checkout_rules:status/0` returns the same as maps.
""".
-spec status() -> ok.
status() ->
    S = checkout_rules:status(),
    [io:format("~p: active ~p, previous ~p, ~p runtimes, counts ~p~s~n",
               [M, A, P, R, C, breaker(B)])
     || #{merchant := M, active := A, previous := P, runtimes := R,
          counts := C, breaker := B} <- S, M =/= '$validation'],
    ok.

breaker(none) -> "";
breaker(#{from := F, to := T, reason := Why}) ->
    io_lib:format("~n  breaker: version ~p switched off (~p), now ~p",
                  [F, Why, T]).

-doc """
Run checkouts for `Merchants` for `Seconds`, two clients per merchant, and
print one line per merchant: checkouts, outcomes, versions seen, p50 and p99.
`checkout_load:run/2` returns the same as maps.
""".
-spec load([atom()], pos_integer()) -> ok.
load(Merchants, Seconds) ->
    _ = checkout_load:run(Merchants, Seconds),
    ok.

-doc """
A cart of one item at `Cents`, for a customer of tier `Tier` (`~"gold"`,
`~"silver"` or `~"bronze"`): `cart(12000, ~"gold")`.
""".
-spec cart(non_neg_integer(), binary()) -> map().
cart(Cents, Tier) ->
    #{items => [#{sku => ~"basket", price => Cents, qty => 1}],
      currency => ~"EUR", customer => #{id => ~"c-42", tier => Tier}}.
