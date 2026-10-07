import {readFileSync} from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {resolve, join} from 'node:path';

export const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
export function compare(actual, expected, path = '$') {
  if (typeof expected === 'number') {
    if (typeof actual !== 'number' || !Number.isFinite(actual) ||
        Math.abs(actual - expected) > 1e-9) {
      throw new Error(`${path}: ${actual} differs from ${expected}`);
    }
  } else if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) throw new Error(`${path}: array length`);
    expected.forEach((value, index) => compare(actual[index], value, `${path}[${index}]`));
  } else if (expected !== null && typeof expected === 'object') {
    if (actual === null || typeof actual !== 'object' ||
        Object.keys(actual).sort().join(',') !== Object.keys(expected).sort().join(',')) throw new Error(`${path}: keys`);
    for (const key of Object.keys(expected)) compare(actual[key], expected[key], `${path}.${key}`);
  } else if (actual !== expected) {
    // Due and review timestamps are strings: exact equality, no date rounding.
    throw new Error(`${path}: ${actual} differs from ${expected}`);
  }
}

export async function verifyArtifact(directory, requireCertificate = true, corpusPath = null, requirePerfect = true) {
  const engineFile = join(directory, 'engine.mjs');
  const vectorsFile = corpusPath || join(directory, 'vectors.json.gz');
  const engineBytes = readFileSync(engineFile);
  const vectorBytes = readFileSync(vectorsFile);
  const corpus = JSON.parse(gunzipSync(vectorBytes));
  if (corpus.schema !== 'recall.scheduler-vectors/v1' || corpus.histories < 3000 ||
      corpus.vectorCount !== corpus.vectors.length || corpus.vectorCount < 30000 ||
      corpus.historyStates !== '0,1,2,3' || corpus.historyRatings !== '1,2,3,4' ||
      corpus.historyLapseTransitions < 1) {
    throw new Error('Incomplete golden corpus');
  }
  const {schedule, compiledSourceSha256} = await import(pathToFileURL(resolve(engineFile)).href);
  let matched = 0;
  let maxAbsoluteFloatError = 0;
  let dueComparisons = 0;
  let exactDueComparisons = 0;
  let exactReviewedAt = true;
  function measure(actual, expected, key = '') {
    if (typeof expected === 'number') {
      maxAbsoluteFloatError = Math.max(maxAbsoluteFloatError, Math.abs(actual - expected));
    } else if (expected && typeof expected === 'object') {
      for (const [childKey, child] of Object.entries(expected)) measure(actual?.[childKey], child, childKey);
    } else if (key === 'due') {
      dueComparisons++;
      if (actual === expected) exactDueComparisons++;
    } else if (key === 'reviewedAt' && actual !== expected) {
      exactReviewedAt = false;
    }
  }
  const differences = [];
  let index = 0;
  for (const vector of corpus.vectors) {
    const actual = schedule(vector.request);
    measure(actual, vector.expected);
    try {
      compare(actual, vector.expected, `vector[${index}]`);
      matched++;
    } catch (error) {
      differences.push({index, message:error.message});
    }
    index++;
  }
  const result = {schema: 'recall.scheduler-proof/v1', verified: matched === corpus.vectorCount,
    engine: 'Dart FsrsEngine compiled with dart2js', fsrsVersion: corpus.fsrsVersion,
    histories: corpus.histories, vectors: corpus.vectorCount, matched, matchRatio: matched / corpus.vectorCount,
    historyStates: corpus.historyStates, historyRatings: corpus.historyRatings,
    historyLapseTransitions: corpus.historyLapseTransitions,
    floatTolerance: 1e-9, maxAbsoluteFloatError, dueComparisons, exactDueComparisons,
    dueDates: exactDueComparisons === dueComparisons && exactReviewedAt ? 'exact' : 'mismatch',
    engineSha256: sha256(engineBytes), compiledJsSha256: compiledSourceSha256,
    vectorsSha256: sha256(vectorBytes)};
  if (requireCertificate) {
    const proof = JSON.parse(readFileSync(join(directory, 'provenance.json')));
    for (const [key, value] of Object.entries(result)) {
      if (proof[key] !== value) throw new Error(`Scheduler certificate mismatch: ${key}`);
    }
  }
  if (requirePerfect && !result.verified) {
    throw new Error(`${matched}/${corpus.vectorCount} match; grading disabled: ${differences[0].message}`);
  }
  return {...result, differences};
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const result = await verifyArtifact(resolve(process.argv[2] || 'build/scheduler'), true, null, !process.argv.includes('--allow-unverified'));
  console.log(`${result.matched}/${result.vectors} vectors matched (${(100 * result.matchRatio).toFixed(4)}%); grading ${result.verified ? 'enabled' : 'disabled'}; due dates ${result.dueDates}, float tolerance 1e-9; max error \${result.maxAbsoluteFloatError}`);
}
