import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {accurateSmallExp, createNumericMath} from './numeric_math.mjs';

test('compensated exponential matches independent 100-digit binary64 oracle', () => {
  const oracle = JSON.parse(readFileSync(new URL('./numeric_oracle.json', import.meta.url)));
  assert.equal(oracle.caseCount, 529);
  assert.equal(oracle.vectors.length, oracle.caseCount);
  for (const vector of oracle.vectors) {
    assert.equal(accurateSmallExp(vector.x), vector.expected, `exp(${vector.x})`);
  }
});
test('near-midpoint regression preserves low terms through final addition to one', () => {
  const x = 0.017157218632938013;
  assert.equal(accurateSmallExp(x), 1.0173052490937204);
  // A rounded expm1 intermediate double-rounds on the affected V8 backend.
  // The oracle assertion remains portable when the host backend is corrected.
  assert.equal(createNumericMath().exp(x), 1.0173052490937204);
});
test('numeric adapter is local and delegates outside the compensated domain', () => {
  const originalExp = globalThis.Math.exp;
  const math = createNumericMath();
  assert.equal(globalThis.Math.exp, originalExp);
  assert.notEqual(math, globalThis.Math);
  for (const value of [-1, -0.0001, Math.LN2 / 2 + Number.EPSILON, 1, 700, Infinity, -Infinity]) {
    assert.equal(math.exp(value), Math.exp(value));
  }
  assert.ok(Number.isNaN(math.exp(NaN)));
  assert.equal(math.pow(2, 4), 16);
  assert.equal(math.floor(1.8), 1);
  for (const invalid of [-1, 1, NaN, Infinity]) {
    assert.throws(() => accurateSmallExp(invalid), RangeError);
  }
});
