-module(checkout_load).
-moduledoc """
A load generator for the checkout service, so you can watch what a rule
does to its merchant and, more to the point, what it does not do to others.

`run/2` starts two client processes per merchant. Each one sends a random
cart through `checkout:checkout_info/2`, waits for the answer, waits 5 ms
more, and sends the next, until the time is up. One cart in twenty holds the
sku `trap`, which `priv/rules/loop_sometimes.js` loops on. Then it prints
one line per merchant and returns the same figures as maps.

The latencies include waiting for a free runtime: two clients share a
merchant's two runtimes, so they rarely wait.
""".

-export([run/2]).

-define(CLIENTS, 2).
%% Between two checkouts a client waits this long, as a shopper would: a
%% client answered at once by a fallback would otherwise spin.
-define(THINK_MS, 5).

-doc """
Run checkouts for `Merchants` for `Seconds`; print and return, per merchant:
checkouts, outcomes by kind, versions seen, and p50 and p99 in milliseconds.
""".
-spec run([atom()], pos_integer()) -> [map()].
run(Merchants, Seconds) ->
    Until = erlang:monotonic_time(millisecond) + Seconds * 1000,
    Self = self(),
    Clients = [spawn_monitor(fun() -> Self ! {done, M, client(M, Until, [])} end)
               || M <- Merchants, _ <- lists:seq(1, ?CLIENTS)],
    Samples = collect(length(Clients), #{}),
    Rows = [row(M, maps:get(M, Samples, [])) || M <- Merchants],
    print(Rows),
    Rows.

client(M, Until, Acc) ->
    case erlang:monotonic_time(millisecond) >= Until of
        true -> Acc;
        false ->
            {Outcome, V, Micros} = checkout:checkout_info(M, random_cart()),
            timer:sleep(?THINK_MS),
            client(M, Until, [{kind(Outcome), V, Micros} | Acc])
    end.

collect(0, Acc) -> Acc;
collect(N, Acc) ->
    receive
        {done, M, S} ->
            collect(N - 1, maps:update_with(M, fun(Old) -> S ++ Old end, S, Acc));
        {'DOWN', _, process, _, normal} ->
            collect(N, Acc);
        {'DOWN', _, process, _, Why} ->
            error({client_crashed, Why})
    end.

row(M, Samples) ->
    Times = lists:sort([T || {_, _, T} <- Samples]),
    Kinds = lists:foldl(fun({K, _, _}, A) -> maps:update_with(K, fun(N) -> N + 1 end, 1, A) end,
                        #{}, Samples),
    #{merchant => M, checkouts => length(Samples), outcomes => Kinds,
      versions => lists:usort([V || {_, V, _} <- Samples, V =/= none]),
      p50_ms => pct(Times, 50), p99_ms => pct(Times, 99)}.

pct([], _) -> 0.0;
pct(Sorted, P) ->
    I = max(1, round(length(Sorted) * P / 100)),
    round(lists:nth(I, Sorted) / 100) / 10.

print(Rows) ->
    io:format("~-10s ~9s ~8s  ~-52s ~-9s ~7s ~7s~n",
              ["merchant", "checkouts", "ok", "fallbacks", "versions", "p50 ms", "p99 ms"]),
    [io:format("~-10s ~9b ~8b  ~-52s ~-9s ~7.1f ~7.1f~n",
               [atom_to_list(M), N, maps:get(ok, K, 0), fallbacks(K),
                versions(Vs), P50, P99])
     || #{merchant := M, checkouts := N, outcomes := K, versions := Vs,
          p50_ms := P50, p99_ms := P99} <- Rows],
    ok.

fallbacks(K) ->
    case [io_lib:format("~p ~b", [Kind, N]) || {Kind, N} <- lists:sort(maps:to_list(K)), Kind =/= ok] of
        [] -> "-";
        L -> lists:flatten(lists:join(", ", L))
    end.

versions([]) -> "-";
versions(Vs) -> lists:flatten(lists:join(",", [integer_to_list(V) || V <- Vs])).

kind({ok, _}) -> ok;
kind({fallback, {K, _}}) -> K;
kind({fallback, K}) -> K.

%% Between 10 and 300 euros, one to three items, any tier; one cart in twenty
%% holds the sku `trap'.
random_cart() ->
    Items = [#{sku => sku(), price => 500 + rand:uniform(9500),
               qty => rand:uniform(3)}
             || _ <- lists:seq(1, rand:uniform(3))],
    #{items => Items, currency => ~"EUR",
      customer => #{id => ~"c-load",
                    tier => lists:nth(rand:uniform(3), [~"gold", ~"silver", ~"bronze"])}}.

sku() ->
    case rand:uniform(20) of
        1 -> ~"trap";
        _ -> lists:nth(rand:uniform(4), [~"mug", ~"tea", ~"kettle", ~"cup"])
    end.
