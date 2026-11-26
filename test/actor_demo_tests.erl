-module(actor_demo_tests).
-include_lib("eunit/include/eunit.hrl").

%% A and B are two instances of one component: their totals are their own.
%% The new A, started by the supervisor after the kill, starts from nothing,
%% and B, untouched, still holds 3.
actor_demo_test() ->
    ?assertMatch([{counter_a, 2}, {counter_a, 5}, {counter_b, 3},
                  {counter_a, {down, killed}},
                  {counter_a, 1}, {counter_b, 3}],
                 wasm_demo:actor_demo()).

%% Run twice in one node: the first run's supervisor and actors are gone, so
%% the names are free and the totals start again.
actor_demo_runs_again_test() ->
    ?assertEqual(wasm_demo:actor_demo(), wasm_demo:actor_demo()).
