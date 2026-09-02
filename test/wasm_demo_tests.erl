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
