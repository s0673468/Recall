"""Independent 100-digit oracle, using exact binary64 inputs and no user data."""
from decimal import Decimal, localcontext
import json
import math
from pathlib import Path
import random

root = Path(__file__).resolve().parent
random_source = random.Random(20261007)
failing = 0.017157218632938013
inputs = [0.0, failing, math.nextafter(failing, 0),
          math.nextafter(failing, math.inf), math.log(2) / 2]
inputs += [10.0 ** (-power) for power in [1, 2, 3, 6, 8, 12, 15, 16, 17, 30, 100, 300]]
inputs += [random_source.random() * math.log(2) / 2 for _ in range(512)]
with localcontext() as context:
    context.prec = 100
    vectors = [{"x": value, "expected": float(Decimal.from_float(value).exp())}
               for value in inputs]
(root / "numeric_oracle.json").write_text(json.dumps({
    "method": "Decimal100 exact binary64 input; nearest binary64 output",
    "seed": 20261007, "caseCount": len(vectors), "vectors": vectors,
}, indent=2) + "\n")
