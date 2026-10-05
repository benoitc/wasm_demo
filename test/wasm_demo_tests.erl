-module(wasm_demo_tests).
-include_lib("eunit/include/eunit.hrl").

add_test() ->
    ?assertEqual(7, wasm_demo:add(3, 4)).

greet_test() ->
    ?assertEqual(~"hello, erlang!", wasm_demo:greet(~"erlang")).

js_test_() ->
    {timeout, 60, fun() -> round_trip(wasm_demo:js_worker(), 30000) end}.

%% Longer, and it is the first request that needs it: CPython starts in about
%% 33 seconds here and answers in tens of milliseconds after that. The second
%% and third requests are what prove the worker keeps the interpreter alive.
py_test_() ->
    {timeout, 300, fun() -> round_trip(wasm_demo:py_worker(), 240000) end}.

round_trip(W, First) ->
    ?assertEqual(#{~"name" => ~"ADA", ~"n" => 1},
                 wasm_demo:ask(W, #{name => ~"ada", n => 1}, First)),
    ?assertEqual(#{~"x" => ~"Y"}, wasm_demo:ask(W, #{x => ~"y"})),
    ?assertEqual(#{~"z" => ~"Z"}, wasm_demo:ask(W, #{z => ~"z"})),
    ?assertEqual({ok, []}, wasm_demo:stop(W)).

%% No `application:ensure_all_started(wasm)': a component compiles inline
%% when the module cache is not running.
component_test() ->
    T = wasm_demo:text([~"the", ~"a"]),
    ?assertEqual({ok, ~"HELLO, COMPONENT!"}, wasm_demo:shout(T, ~"hello, component")),
    ?assertEqual({error, ~"nothing to shout"}, wasm_demo:shout(T, ~"  ")),
    H = wasm_demo:tally(T),
    ?assertEqual(3, wasm_demo:count(T, H, ~"the cat saw the dog")),
    ?assertEqual(3, wasm_demo:count(T, H, ~"a cat, a dog")),
    ?assertEqual([#{~"word" => ~"cat", ~"n" => 2}, #{~"word" => ~"dog", ~"n" => 2}],
                 wasm_demo:top(T, H, 2)),
    ?assertEqual(ok, wasm_demo:drop(T, H)),
    ?assertMatch({error, #{class := trap, kind := resource_not_live}}, wasm_demo:drop(T, H)),
    ?assertError({badmatch, {error, #{kind := resource_not_live}}}, wasm_demo:count(T, H, ~"cat")),
    ?assertEqual(ok, wasm_demo:close(T)).
