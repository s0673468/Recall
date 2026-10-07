/**
 * Binary64 Math.exp backends can differ by an ULP near 1. FSRS then subtracts
 * 1 and amplifies that error. Retain ~106-bit intermediates over [0, ln(2)/2]
 * before the final binary64 conversion. No card-specific branches or rounding
 * of scheduler outcomes are used. The native Dart engine is unchanged.
 *
 * TwoSum and Dekker's split-product are error-free transforms; the positive
 * Taylor series avoids cancellation. At x <= ln(2)/2 its remaining tail after
 * a term < 1e-35 is below 1e-35. Outside this range use the supplied native math.
 */
export function accurateSmallExp(x) {
  if (!Number.isFinite(x) || x < 0 || x > globalThis.Math.LN2 / 2) {
    throw new RangeError('accurateSmallExp requires 0 <= x <= ln(2)/2');
  }
  function twoSum(a, b) {
    const high = a + b;
    const virtual = high - a;
    return [high, (a - (high - virtual)) + (b - virtual)];
  }
  function twoProduct(a, b) {
    const high = a * b;
    const split = 134217729; // 2^27 + 1, splitting a binary64 significand.
    const splitA = split * a;
    const splitB = split * b;
    const highA = splitA - (splitA - a);
    const highB = splitB - (splitB - b);
    const lowA = a - highA;
    const lowB = b - highB;
    return [high, ((highA * highB - high) + highA * lowB + lowA * highB) + lowA * lowB];
  }
  function add(a, b) {
    const sum = twoSum(a[0], b[0]);
    return twoSum(sum[0], sum[1] + a[1] + b[1]);
  }
  function multiply(a, b) {
    const product = twoProduct(a[0], b);
    return twoSum(product[0], product[1] + a[1] * b);
  }
  function divide(a, b) {
    const quotient = a[0] / b;
    const product = twoProduct(quotient, b);
    const remainder = add(a, [-product[0], -product[1]]);
    return twoSum(quotient, (remainder[0] + remainder[1]) / b);
  }
  let term = [1, 0];
  let sum = [1, 0];
  for (let n = 1; n <= 32; n++) {
    term = divide(multiply(term, x), n);
    sum = add(sum, term);
    if (term[0] < 1e-35) break;
  }
  return sum[0] + sum[1];
}

export function createNumericMath(nativeMath = globalThis.Math) {
  const math = Object.create(nativeMath);
  math.exp = (x) => x >= 0 && x <= nativeMath.LN2 / 2
    ? accurateSmallExp(x)
    : nativeMath.exp(x);
  return math;
}
