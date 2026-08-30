-module(wasm_demo_tests).
-include_lib("eunit/include/eunit.hrl").

add_test() ->
    ?assertEqual(7, wasm_demo:add(3, 4)).

greet_test() ->
    ?assertEqual(~"hello, erlang!", wasm_demo:greet(~"erlang")).

js_test_() ->
    {timeout, 60, fun() ->
        W = wasm_demo:js_worker(),
        ?assertEqual(#{~"name" => ~"ADA", ~"n" => 1},
                     wasm_demo:js_ask(W, #{name => ~"ada", n => 1})),
        ?assertEqual(#{~"x" => ~"Y"}, wasm_demo:js_ask(W, #{x => ~"y"})),
        ?assertEqual({ok, []}, wasm_demo:js_stop(W))
    end}.
