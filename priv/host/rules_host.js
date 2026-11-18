// A merchant's rule runtime. QuickJS starts once and runs this loop for as
// long as the runtime lives; rules are added to it while it runs. One JSON
// request per line on standard input, one answer per line on standard output:
//
//   {"op":"define","version":V,"source":S}  compile S, keep it as version V
//   {"op":"activate","version":V}           checkouts now call V (null: none)
//   {"op":"call","cart":C}                  run the active rule on cart C
//   {"op":"drop","version":V}               forget version V
//
// An answer is {"ok":..., "v":active} or {"error":"...", "v":active}, plus
// "logs" when the rule printed anything. A rule is a script that defines
// `function main(cart)`. It is compiled once, at define, so a checkout calls
// a function that already exists.
import * as std from "qjs:std";

// What a rule prints is kept and returned, never written to standard output,
// where it would read as an answer.
let logs = [];
const keep = (...args) => { logs.push(args.map(String).join(" ")); };
globalThis.console = { log: keep, info: keep, warn: keep, error: keep, debug: keep };
globalThis.print = keep;

const versions = new Map();
let active = null;

function define(version, source) {
  const main = new Function(
    source + "\n;return typeof main === 'function' ? main : undefined;")();
  if (typeof main !== "function") {
    throw new Error("the rule does not define function main(cart)");
  }
  versions.set(version, main);
  return version;
}

function handle(req) {
  switch (req.op) {
    case "define":
      return define(req.version, req.source);
    case "activate":
      if (req.version !== null && !versions.has(req.version)) {
        throw new Error("no version " + req.version);
      }
      active = req.version;
      return active;
    case "call":
      return active === null ? [] : versions.get(active)(req.cart);
    case "drop":
      versions.delete(req.version);
      return req.version;
    default:
      throw new Error("unknown op " + req.op);
  }
}

let line;
while ((line = std.in.getline()) !== null) {
  logs = [];
  let answer;
  try {
    answer = { ok: handle(JSON.parse(line)) };
  } catch (e) {
    answer = { error: String(e && e.message ? e.message : e) };
  }
  answer.v = active;
  if (logs.length > 0) answer.logs = logs;
  std.out.puts(JSON.stringify(answer) + "\n");
  std.out.flush();
}
