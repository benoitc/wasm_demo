# One JSON object per line in, one per line out: uppercase every string.
# The same contract as worker.js, in a language that also knows nothing about
# Erlang. `-u' on the command line is what stops CPython holding a reply in a
# block buffer.
import sys, json

for line in sys.stdin:
    req = json.loads(line)
    out = {k: (v.upper() if isinstance(v, str) else v) for k, v in req.items()}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
