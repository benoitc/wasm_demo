-module(checkout_tests).
-moduledoc """
The checkout rules service, one case per claim `docs/checkout.md` makes.

They share one running service, started once, and each uses merchants of
its own so they do not see each other's rules.
""".
-include_lib("eunit/include/eunit.hrl").

checkout_test_() ->
    {setup,
     fun() -> ok = checkout:start() end,
     fun(_) -> checkout:stop() end,
     [{timeout, 60, fun a_rule_gives_discounts/0},
      {timeout, 60, fun a_bad_rule_is_refused_at_upload/0},
      {timeout, 60, fun a_rule_can_be_tried_with_its_logs/0},
      {timeout, 60, fun a_looping_rule_falls_back_and_others_are_untouched/0},
      {timeout, 60, fun a_hot_swap_loses_no_checkout_and_restarts_nothing/0},
      {timeout, 60, fun a_rule_that_keeps_failing_is_switched_off/0}]}.

a_rule_gives_discounts() ->
    ?assertEqual({ok, 1}, checkout:upload(t_big, checkout:rule(big_order))),
    ?assertMatch({ok, [#{~"code" := ~"BIG10", ~"percent" := 10}]},
                 checkout:checkout(t_big, checkout:cart(12000, ~"bronze"))),
    ?assertEqual({ok, []}, checkout:checkout(t_big, checkout:cart(5000, ~"gold"))),
    ?assertEqual({fallback, no_rule},
                 checkout:checkout(t_nobody, checkout:cart(12000, ~"gold"))).

a_bad_rule_is_refused_at_upload() ->
    ?assertMatch({error, {timeout, _}}, checkout:upload(t_bad, checkout:rule(loop))),
    ?assertMatch({error, {throws, ~"fetch is not defined", _}},
                 checkout:upload(t_bad, checkout:rule(fetch))),
    ?assertMatch({error, {bad_result, {bad_discount, _, {percent_out_of_bounds, 200}}, _}},
                 checkout:upload(t_bad, checkout:rule(greedy))),
    ?assertMatch({error, {does_not_compile, _}},
                 checkout:upload(t_bad, ~"var main = 42;")),
    %% None of them went live.
    ?assertEqual({fallback, no_rule},
                 checkout:checkout(t_bad, checkout:cart(12000, ~"gold"))).

a_rule_can_be_tried_with_its_logs() ->
    Rule = ~"function main(cart) { console.log('tier', cart.customer.tier); return []; }",
    ?assertEqual({ok, [], [~"tier gold"]},
                 checkout:try_rule(Rule, checkout:cart(100, ~"gold"))).

%% The rule loops on a cart holding the sku `trap'. That checkout falls back
%% at the deadline, its runtime is killed and comes back with the rule, and
%% another merchant's checkouts answer in time meanwhile.
a_looping_rule_falls_back_and_others_are_untouched() ->
    {ok, 1} = checkout:upload(t_loop, checkout:rule(loop_sometimes)),
    {ok, 1} = checkout:upload(t_calm, checkout:rule(big_order)),
    Trap = #{items => [#{sku => ~"trap", price => 100, qty => 1}],
             currency => ~"EUR", customer => #{id => ~"c", tier => ~"gold"}},
    Self = self(),
    spawn_link(fun() -> Self ! {calm, [checkout:checkout_info(t_calm, checkout:cart(12000, ~"gold"))
                                       || _ <- lists:seq(1, 20)]} end),
    {Outcome, _, Micros} = checkout:checkout_info(t_loop, Trap),
    ?assertEqual({fallback, timeout}, Outcome),
    ?assert(Micros < 300_000),
    Calm = receive {calm, C} -> C end,
    ?assertEqual([], [O || {O, _, _} <- Calm, element(1, O) =/= ok]),
    ?assertEqual([], [T || {_, _, T} <- Calm, T >= 100_000]),
    %% Back with its rule once its runtime has restarted.
    ?assertMatch({ok, [#{~"code" := ~"WELCOME"}]},
                 eventually(fun() -> checkout:checkout(t_loop, checkout:cart(1000, ~"gold")) end)).

%% Two clients check out while version 2 is uploaded: every checkout gets an
%% answer, both versions answer some, and the runtimes are the same processes
%% before and after, because a rule is added to a running runtime.
a_hot_swap_loses_no_checkout_and_restarts_nothing() ->
    {ok, 1} = checkout:upload(t_swap, checkout:rule(big_order)),
    Before = lists:sort(checkout_rules:runtimes(t_swap)),
    Self = self(),
    Until = erlang:monotonic_time(millisecond) + 1500,
    Clients = [spawn_link(fun() -> Self ! {done, client(t_swap, Until, [])} end)
               || _ <- [1, 2]],
    timer:sleep(500),
    ?assertEqual({ok, 2}, checkout:upload(t_swap, checkout:rule(big_order_v2))),
    Results = lists:append([receive {done, R} -> R end || _ <- Clients]),
    ?assertEqual([], [O || {O, _, _} <- Results, element(1, O) =/= ok]),
    ?assertEqual([1, 2], lists:usort([V || {_, V, _} <- Results])),
    ?assertEqual(Before, lists:sort(checkout_rules:runtimes(t_swap))),
    %% Version 2 gives 15% over 150 €; rolling back gives version 1's 10%.
    Cart = checkout:cart(16000, ~"gold"),
    ?assertMatch({ok, [#{~"code" := ~"BIG15"}]}, checkout:checkout(t_swap, Cart)),
    ?assertEqual({ok, 1}, checkout:rollback(t_swap)),
    ?assertMatch({ok, [#{~"code" := ~"BIG10"}]}, checkout:checkout(t_swap, Cart)).

%% `flaky' throws on an odd total. Five throws in a row and the breaker puts
%% the previous version, `gold_shipping', back.
a_rule_that_keeps_failing_is_switched_off() ->
    {ok, 1} = checkout:upload(t_flaky, checkout:rule(gold_shipping)),
    {ok, 2} = checkout:upload(t_flaky, checkout:rule(flaky)),
    Odd = checkout:cart(3001, ~"gold"),
    [?assertMatch({fallback, {throws, _}}, checkout:checkout(t_flaky, Odd))
     || _ <- lists:seq(1, 5)],
    ?assertMatch({ok, [#{~"code" := ~"GOLDSHIP"}]},
                 eventually(fun() -> checkout:checkout(t_flaky, Odd) end)),
    [#{active := 1, breaker := #{from := 2, to := 1}}] =
        [S || S = #{merchant := t_flaky} <- checkout_rules:status()].

%%% ------------------------------------------------------------- helpers ---

client(M, Until, Acc) ->
    case erlang:monotonic_time(millisecond) >= Until of
        true -> Acc;
        false -> client(M, Until, [checkout:checkout_info(M, checkout:cart(12000, ~"gold")) | Acc])
    end.

%% The answer of `F' once it is `{ok, _}', trying for up to three seconds.
eventually(F) -> eventually(F, 60).

eventually(F, 0) -> F();
eventually(F, N) ->
    case F() of
        {ok, _} = Ok -> Ok;
        _ -> timer:sleep(50), eventually(F, N - 1)
    end.
