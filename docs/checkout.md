# Checkout rules

This part of the demo is a shop's checkout service where each merchant
writes their own discount rule in JavaScript, and the service runs it on
every checkout. It is the kind of thing WebAssembly in an Erlang application
is for:

- code you did not write, from many tenants;
- a strict time budget on a hot path;
- failures that stay with the tenant who caused them;
- code that changes while traffic flows.

Read this page to run it, to write your own rule, and to see what happens
when a rule misbehaves.

Each merchant's rule runs in **warm runtimes**. A runtime is a QuickJS
interpreter, compiled to WebAssembly, that starts once and keeps running. A
rule is added to it on the fly: the runtime compiles the merchant's source
into a function and keeps it, so a checkout calls a function that already
exists. Nothing starts and nothing is parsed on the checkout path.

## Before you start

You need Erlang/OTP 29 or later and `rebar3`, and the QuickJS interpreter
that `make priv` downloads once, about 1.5 MB. You need no Rust and no WASI
SDK.

```sh
make priv
make shell
```

Every example below is typed in that shell. The outputs are real, from one
run on one machine whose load average was between 26 and 38 (it is shared),
so read the times as their shape, not as numbers you will see.

## Use it, step by step

### Start the service

```erlang
1> checkout:start().
ok
```

This starts the `wasm` application, compiles QuickJS once for the node, and
starts the service's supervision tree. It took 0.27 s here.

### Upload a rule

A rule is a script that defines `function main(cart)`. The examples are in
`priv/rules/`, and `checkout:rule/1` reads one by name:

```erlang
2> checkout:upload(a, checkout:rule(big_order)).
{ok,1}
3> checkout:upload(c, checkout:rule(gold_shipping)).
{ok,1}
```

Merchants are atoms: `a` and `c` here. `{ok, 1}` is the version number.
Before a rule goes live, it is run on three sample carts in a separate
runtime. A rule that fails there is refused, so it never reaches the
merchant's runtimes (see [Refused rules](#refused-rules)). The first upload
for a merchant also starts its two runtimes, and took 0.8 s here. Later
uploads restart nothing.

You can also upload a string:

```erlang
4> checkout:upload(d, "function main(cart) { return []; }").
{ok,1}
```

### Run a checkout

```erlang
5> checkout:checkout(a, checkout:cart(12000, ~"bronze")).
{ok,[#{<<"code">> => <<"BIG10">>,<<"percent">> => 10,
       <<"reason">> => <<"order over 100 EUR">>}]}
6> checkout:checkout(a, checkout:cart(5000, ~"bronze")).
{ok,[]}
7> checkout:checkout(c, checkout:cart(3000, ~"gold")).
{ok,[#{<<"amount">> => 500,<<"code">> => <<"GOLDSHIP">>,
       <<"reason">> => <<"free shipping for gold">>}]}
8> checkout:checkout(b, checkout:cart(3000, ~"gold")).
{fallback,no_rule}
```

`checkout:cart(Cents, Tier)` builds a one-item cart; prices are in cents.
A checkout never fails. It answers `{ok, Discounts}` or
`{fallback, Reason}`, which means "no discount" and why. Here `b` has no
rule yet. [What happens when a rule misbehaves](#what-happens-when-a-rule-misbehaves)
lists the reasons.

### See the merchants

```erlang
9> checkout:status().
a: active 1, previous none, 2 runtimes, counts #{ok => 2}
c: active 1, previous none, 2 runtimes, counts #{ok => 1}
d: active 1, previous none, 2 runtimes, counts #{}
ok
```

For each merchant you see:

- the active version and the previous one, which `rollback/1` goes back to;
- how many runtimes are alive;
- how many checkouts ended in each outcome.

When the breaker switched a rule off, a second line says which version and
why.

### Put it under load

```erlang
10> checkout:load([a, c], 10).
merchant   checkouts       ok  fallbacks                                            versions   p50 ms  p99 ms
a                882      882  -                                                    1            15.0    45.9
c                925      925  -                                                    1            13.9    43.7
ok
```

`load/2` runs two shoppers per merchant for 10 seconds. Each sends a random
cart, waits for the answer, then waits 5 ms before the next. The times are
for the whole checkout as the caller sees it, including JSON in and out of
the guest.

### Change a rule while it runs

Upload version 2 while checkouts are going on. Here `load/2` runs in the
shell and the upload is made 3 seconds into it, from another process:

```erlang
11> spawn(fun() -> timer:sleep(3000), checkout:upload(a, checkout:rule(big_order_v2)) end),
    checkout:load([a, c], 10).
merchant   checkouts       ok  fallbacks                                            versions   p50 ms  p99 ms
a                889      889  -                                                    1,2          15.6    35.3
c                942      942  -                                                    1            14.2    30.4
ok
```

Every checkout got an answer, and `a`'s were answered by both versions. The
new version was compiled into `a`'s two running runtimes, then switched on
in each. No runtime restarted. Version 2 gives 15% over 150 EUR:

```erlang
12> checkout:checkout(a, checkout:cart(16000, ~"gold")).
{ok,[#{<<"code">> => <<"BIG15">>,<<"percent">> => 15,
       <<"reason">> => <<"order over 150 EUR">>}]}
13> checkout:rollback(a).
{ok,1}
14> checkout:checkout(a, checkout:cart(16000, ~"gold")).
{ok,[#{<<"code">> => <<"BIG10">>,<<"percent">> => 10,
       <<"reason">> => <<"order over 100 EUR">>}]}
```

`rollback/1` switches back the same way, live.

### Stop

```erlang
15> checkout:stop().
ok
```

The rules are not kept: the next `start/0` begins empty.

## Write your own rule

A rule is a script that defines `function main(cart)` and returns the
discounts for that cart.

What `cart` holds:

| field | what it is |
| --- | --- |
| `items` | a list of `{sku, price, qty}`, with `price` in cents |
| `currency` | `"EUR"` |
| `customer` | `{id, tier}`, where `tier` is `"gold"`, `"silver"` or `"bronze"` |

The platform fills in `customer`. A rule cannot look anything up for itself:
it has no network, no files and no way to call back into Erlang.

What `main` returns is a list of discounts, at most 5. Each one has:

- a `code`, a non-empty string;
- **either** a `percent`, more than 0 and at most 100, **or** an `amount` in
  cents, more than 0 and at most the cart's total;
- optionally a `reason`.

Anything else counts as a failure of the rule, the same as a throw.

A rule for silver customers:

```javascript
// 3% off for silver customers who buy three items or more.
function main(cart) {
  const count = cart.items.reduce((n, item) => n + item.qty, 0);
  if (cart.customer.tier !== "silver" || count < 3) return [];
  return [{ code: "SILVER3", percent: 3, reason: "three items or more" }];
}
```

Save it as `priv/rules/silver.js` and upload it with
`checkout:upload(e, checkout:rule(silver))`, or pass the source as a string.

### Try a rule before you upload it

`checkout:try_rule/2` runs a rule on a cart of your own in the validation
runtime, without activating it anywhere. It also returns what the rule
printed with `console.log`, which a live rule cannot show you:

```erlang
16> checkout:try_rule("function main(cart) {
      console.log(\"tier\", cart.customer.tier);
      return [];
    }", checkout:cart(2500, ~"gold")).
{ok,[],[<<"tier gold">>]}
```

It answers `{ok, Discounts, Logs}` or `{error, Why, Logs}`.

### Refused rules

`upload/2` refuses a rule that fails on one of the three sample carts, and
names the cart. The checks run in a separate runtime, so a bad rule never
touches live traffic:

```erlang
17> checkout:upload(b, checkout:rule(loop)).
{error,{timeout,#{items => [#{price => 1500,qty => 1,sku => <<"mug">>}],
                  currency => <<"EUR">>,
                  customer => #{id => <<"c-1">>,tier => <<"bronze">>}}}}
18> checkout:upload(b, checkout:rule(fetch)).
{error,{throws,<<"fetch is not defined">>,
               #{items => [#{price => 1500,qty => 1,sku => <<"mug">>}],
                 currency => <<"EUR">>,
                 customer => #{id => <<"c-1">>,tier => <<"bronze">>}}}}
19> checkout:upload(b, checkout:rule(greedy)).
{error,{bad_result,{bad_discount,#{<<"code">> => <<"FREE">>,
                                   <<"percent">> => 200,
                                   <<"reason">> => <<"everything must go">>},
                                 {percent_out_of_bounds,200}},
                   #{items => [#{price => 1500,qty => 1,sku => <<"mug">>}],
                     currency => <<"EUR">>,
                     customer => #{id => <<"c-1">>,tier => <<"bronze">>}}}}
```

| refusal | why |
| --- | --- |
| `{does_not_compile, Msg}` | a syntax error, or no `function main` |
| `{throws, Msg, Cart}` | `main` threw on that cart; `fetch is not defined` because the sandbox has no network |
| `{timeout, Cart}` | `main` did not answer within the deadline, 100 ms |
| `{bad_result, Why, Cart}` | the answer broke a bound: not a list, too many discounts, a bad `code`, `percent` or `amount` |

The three sample carts are `checkout_rules:sample_carts/0`: a small order,
a 210 EUR order from a gold customer, and an empty cart.

## What happens when a rule misbehaves

A rule can pass the samples and still go wrong on real carts. Two examples
do that on purpose:

- `loop_sometimes.js` loops forever on a cart that holds the sku `trap`;
- `flaky.js` throws on a cart whose total is an odd number of cents.

`load/2` sends a `trap` item in one cart out of twenty:

```erlang
20> checkout:upload(b, checkout:rule(loop_sometimes)).
{ok,1}
21> checkout:load([a, b, c], 10).
merchant   checkouts       ok  fallbacks                                            versions   p50 ms  p99 ms
a                846      846  -                                                    1            17.0    36.0
b               1423      257  no_runtime 1122, runtime_restarted 20, timeout 24    1             0.0   101.0
c                889      889  -                                                    1            15.6    35.5
ok
```

`a` and `c` lost nothing, and their latencies are what they were without
`b`.

`b` paid for its own rule. Each `trap` cart ran until the 100 ms deadline,
and then that runtime was killed and started again with `b`'s rule. While
both of `b`'s runtimes were starting again, its other checkouts found none
and fell back at once (`no_runtime`). Checkouts already waiting on a killed
runtime were told so (`runtime_restarted`).

```erlang
22> checkout:upload(c, checkout:rule(flaky)).
{ok,2}
23> checkout:load([c], 5).
=WARNING REPORT==== 18-Nov-2026::16:18:22.315905 ===
checkout: c's rule 2 tripped the breaker ({fallback,
                                           {throws,
                                            <<"price service unavailable">>}}); now 1
merchant   checkouts       ok  fallbacks                                            versions   p50 ms  p99 ms
c                475      437  throws 38                                            1,2          14.0    32.2
ok
24> checkout:status().
a: active 1, previous 2, 2 runtimes, counts #{ok => 2621}
b: active 1, previous none, 2 runtimes, counts #{timeout => 24,ok => 257,
                                                 no_rule => 1,
                                                 no_runtime => 1122,
                                                 runtime_restarted => 20}
c: active 1, previous none, 2 runtimes, counts #{ok => 3194,throws => 38}
  breaker: version 2 switched off ({fallback,
                                    {throws,<<"price service unavailable">>}}), now 1
d: active 1, previous none, 2 runtimes, counts #{}
ok
```

After five failures of the rule in a row, the **breaker** switched `c` back
to its previous version, `gold_shipping`, and logged it once.

| the rule | the checkout gets | the merchant's runtime | the breaker |
| --- | --- | --- | --- |
| loops | `{fallback, timeout}` at 100 ms | killed, started again with the rule | counts it |
| throws | `{fallback, {throws, Msg}}` | keeps running | counts it |
| uses `fetch`, `require`, files | `{fallback, {throws, Msg}}`: none of them exists | keeps running | counts it |
| answers out of bounds | `{fallback, {bad_result, Why}}` | keeps running | counts it |
| fails 5 times in a row | the previous version answers, or no rule | keeps running, switched | trips, logs once |

A checkout that finds no runtime (`no_runtime`, `runtime_restarted`) is
counted, but it is not the rule's failure, so the breaker ignores it.

## How it works

```text
 checkout:checkout(Merchant, Cart)
   |-- one of the merchant's runtimes, in turn          checkout_rules:pick/1
   |      a process that owns one QuickJS instance, warm, rule compiled
   |      the cart goes in as one JSON line; wait at most 100 ms
   |      no answer: kill the process; its supervisor starts a fresh one,
   |      which compiles the active rule before it takes a checkout
   |-- the answer checked against the bounds          checkout_rules:check_result/2
   |-- the outcome counted, the breaker fed            checkout_rules:record/2
   +-> {ok, Discounts} | {fallback, Reason}
```

**A runtime** (`checkout_runtime`) is an Erlang process that runs QuickJS
on `priv/host/rules_host.js`. That program reads one JSON request per line on
standard input and writes one answer per line. The process spends its whole
life inside the guest's `_start`: the guest blocks reading standard input,
which in Erlang is a `receive` waiting for the next request. The program
understands four requests:

| request | what it does |
| --- | --- |
| `define` | compiles a source into a function and keeps it as a version |
| `activate` | makes a version the one checkouts call |
| `call` | runs the active version on a cart |
| `drop` | forgets a version |

**A rule is added on the fly** by `define`, then `activate`. `upload/2`
first defines the new version in every runtime of the merchant, then
activates it in every one. So a checkout is answered by the old version or
the new one, and never fails in between. A runtime answers one request at a
time, so a switch always happens between two checkouts.

**The deadline** is the caller's. `checkout_runtime:call/3` waits 100 ms,
then kills the runtime. A WebAssembly guest in erlang_wasm is interpreted by
Erlang code, so killing the process stops it at once, and its memory goes
with it.

**Other merchants are not slowed** for two reasons:

- the BEAM preempts a looping guest like any other Erlang process, so it
  cannot hold a scheduler;
- each merchant has its own pool supervisor (`checkout_sup`), so restarting
  `b`'s runtimes keeps only `b`'s supervisor busy.

**What a runtime can reach.** No network, and one read-only directory that
holds `rules_host.js` and nothing else, so no merchant can read another's
source.

## The trade-offs

- **Isolation is per merchant, not per checkout.** A rule's global variables
  persist between its checkouts in a runtime, because the runtime is reused.
  That is the price of a warm runtime, and the right one for a rule: what
  one merchant's code does can only affect that merchant's checkouts.
  erlang_wasm can also give every request a fresh instance, restored from an
  image of a started engine: its worker kernel (`wasm_script_worker` with
  `wasm_javascript`) does that. The choice is isolation per request against
  keeping each merchant's compiled rules warm.
- **A runtime that is killed costs about a quarter of a second** to start
  again (258 ms here), during which that merchant has one runtime fewer. A merchant whose rule
  loops often is mostly unavailable, as `b` was above. That is its own
  problem, and the breaker is there for the rest.
- **Rules are not persisted**, and the platform offers rules nothing beyond
  the cart: no host functions, no HTTP endpoint. This is a demo of the
  sandbox, not a product.

## The API

| function | what it does | answers |
| --- | --- | --- |
| `checkout:start()` | start the service | `ok` |
| `checkout:stop()` | stop it and every runtime | `ok` |
| `checkout:upload(M, Source)` | check a rule and make it `M`'s active one, live | `{ok, Version}` or `{error, Why}` |
| `checkout:rule(Name)` | the source of `priv/rules/Name.js` | a binary |
| `checkout:try_rule(Source, Cart)` | run a rule on a cart without activating it | `{ok, Discounts, Logs}` or `{error, Why, Logs}` |
| `checkout:checkout(M, Cart)` | run a cart through `M`'s rule | `{ok, Discounts}` or `{fallback, Reason}` |
| `checkout:checkout_info(M, Cart)` | the same, with the version and the time in µs | `{Outcome, Version, Micros}` |
| `checkout:rollback(M)` | switch `M` back to its previous version | `{ok, Version}` or `{error, no_previous}` |
| `checkout:status()` | print every merchant's state | `ok` |
| `checkout:load(Ms, Seconds)` | run checkouts and print a table | `ok` |
| `checkout:cart(Cents, Tier)` | a one-item cart | a map |

`checkout_rules:status/0` and `checkout_load:run/2` return as maps what
`status/0` and `load/2` print.

## Tests

`make test` runs them with the rest of the demo, in `test/checkout_tests.erl`:

- `a_rule_gives_discounts`: an uploaded rule answers, and a merchant without
  a rule falls back.
- `a_bad_rule_is_refused_at_upload`: a loop, `fetch`, an out-of-bounds answer
  and a source without `main` are refused, and none goes live.
- `a_rule_can_be_tried_with_its_logs`: `try_rule/2` returns what the rule
  printed.
- `a_looping_rule_falls_back_and_others_are_untouched`: a loop falls back in
  under 300 ms, another merchant's checkouts all answer in under 100 ms
  meanwhile, and the looping merchant's runtime comes back with its rule.
- `a_hot_swap_loses_no_checkout_and_restarts_nothing`: every checkout during
  an upload answers, both versions answer, the runtimes are the same
  processes after, and rollback works.
- `a_rule_that_keeps_failing_is_switched_off`: five throws in a row bring
  the previous version back, and `status` says so.

## Read this next

In the erlang_wasm guides:

- [Streams](https://github.com/benoitc/erlang_wasm/blob/main/docs/streams.md):
  talking to a guest that keeps running, which is what a runtime does here.
- [Security](https://github.com/benoitc/erlang_wasm/blob/main/docs/security.md):
  what the sandbox guarantees and what it leaves to you.
- [JavaScript](https://github.com/benoitc/erlang_wasm/blob/main/docs/javascript.md):
  the worker kernel's JavaScript adapters, for a fresh instance per request.
- [Configuration](https://github.com/benoitc/erlang_wasm/blob/main/docs/configuration.md):
  every limit you can set.
