-module(checkout_sup).
-moduledoc """
The checkout service's supervision tree.

```text
checkout_sup                 rest_for_one
  +-- checkout_rules         the registry; loads QuickJS once
  +-- checkout_pools         simple_one_for_one: one supervisor per merchant
        +-- pool of a        one_for_one: a's runtimes, permanent
        +-- pool of b        ...
        +-- pool of '$validation'   the runtime new rules are tried in
```

Each merchant has its own pool supervisor, so a runtime killed at a
checkout's deadline is restarted by its merchant's supervisor, in parallel
with any other merchant's, and comes back with the merchant's active rule. A
merchant whose rule keeps looping keeps its own supervisor busy and nobody
else's. `rest_for_one`: if the registry goes, the runtimes go with it, since
the rules they run lived in its tables.
""".
-behaviour(supervisor).

-export([start_link/0, start_pool/2]).
-export([init/1]).

-doc false.
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, top).

-doc """
Start `Merchant`'s pool of `Size` runtimes. Returns once every runtime is
warm.
""".
-spec start_pool(atom(), pos_integer()) -> {ok, pid()}.
start_pool(Merchant, Size) ->
    supervisor:start_child(checkout_pools, [{pool, Merchant, Size}]).

-doc false.
init(top) ->
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 10},
          [#{id => checkout_rules,
             start => {checkout_rules, start_link, []}},
           #{id => checkout_pools,
             start => {supervisor, start_link,
                       [{local, checkout_pools}, ?MODULE, pools]},
             type => supervisor}]}};
init(pools) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 10},
          [#{id => pool,
             start => {supervisor, start_link, [?MODULE]},
             restart => permanent,
             type => supervisor}]}};
%% A merchant's runtimes. Generous, because a rule that loops gets a runtime
%% killed on every checkout it loops on, and that is the service working.
init({pool, Merchant, Size}) ->
    {ok, {#{strategy => one_for_one, intensity => 1000, period => 10},
          [#{id => {runtime, I},
             start => {checkout_runtime, start_link, [Merchant, I]},
             restart => permanent,
             shutdown => brutal_kill}
           || I <- lists:seq(1, Size)]}}.
