%% The supervisor behind `wasm_demo:actor_demo/0': two counter actors, each a
%% C component (actor/src/counter.c, committed as priv/counter.component.wasm)
%% in an OTP process of its own. Everything one posts goes to `Observer',
%% tagged with which actor posted it.
-module(counter_actors).
-behaviour(supervisor).

-export([start_link/1, message/0, start_actor/2]).
-export([init/1]).

-define(COMPONENT, {?MODULE, component}).

start_link(Observer) ->
    supervisor:start_link(?MODULE, Observer).

%% The `message' variant of actor/wit/counter.wit, as the host describes it.
%% The guest and the host each hold a copy of the type; this is the host's.
message() ->
    {variant, [{~"add", u32}, {~"added", u32}]}.

%% The component is prepared once, here, so a restart instantiates it
%% without decoding it again. It is kept in `persistent_term' and not in the
%% child specs: a supervisor prints a child's start arguments in every crash
%% report, and a prepared component is far too big to read there.
init(Observer) ->
    Bin = wasm_demo:guest(code:priv_dir(wasm_demo), "counter.component.wasm"),
    {ok, Prepared} = wasm_component:prepare(Bin),
    %% Held by this supervisor, the component's core module stays loaded
    %% while an actor restarts, so a restart never loads it again.
    ok = wasm_component:hold(Prepared),
    ok = persistent_term:put(?COMPONENT, Prepared),
    {ok, {#{strategy => one_for_one, intensity => 3, period => 10},
          [child(counter_a, Observer), child(counter_b, Observer)]}}.

child(Name, Observer) ->
    #{id => Name, start => {?MODULE, start_actor, [Name, Observer]}}.

%% Registered under `Name', so a sender finds the replacement after a
%% restart by the same name.
start_actor(Name, Observer) ->
    To = fun(Msg) -> Observer ! {Name, Msg}, ok end,
    wasm_actor:start_link(persistent_term:get(?COMPONENT),
                          #{message => message(), register => Name, to => To}).
