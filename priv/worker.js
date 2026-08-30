// One JSON object per line in, one per line out: uppercase every string.
import * as std from "qjs:std";
let line;
while ((line = std.in.getline()) !== null) {
  const req = JSON.parse(line);
  const out = {};
  for (const k in req) out[k] = typeof req[k] === "string" ? req[k].toUpperCase() : req[k];
  std.out.puts(JSON.stringify(out) + "\n");
}
