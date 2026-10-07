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

export async function verifyArtifact(directory, requireCertificate = true, corpusPath = null) {
  const engineFile = join(directory, 'engine.mjs');
  const vectorsFile = corpusPath || join(directory, 'vectors.json.gz');
  const engineBytes = readFileSync(engineFile);
  const vectorBytes = readFileSync(vectorsFile);
  const corpus = JSON.parse(gunzipSync(vectorBytes));
  if (corpus.schema !== 'recall.scheduler-vectors/v1' || corpus.histories < 3000 ||
      corpus.vectorCount !== corpus.vectors.length || corpus.vectorCount < 30000) {
    throw new Error('Incomplete golden corpus');
  }
  const {schedule, compiledSourceSha256} = await import(pathToFileURL(resolve(engineFile)).href);
  let matched = 0;
  for (const vector of corpus.vectors) {
    compare(schedule(vector.request), vector.expected, `vector[${matched}]`);
    matched++;
  }
  const result = {schema: 'recall.scheduler-proof/v1', verified: true,
    engine: 'Dart FsrsEngine compiled with dart2js', fsrsVersion: corpus.fsrsVersion,
    histories: corpus.histories, vectors: corpus.vectorCount, matched, matchRatio: 1,
    floatTolerance: 1e-9, dueDates: 'exact',
    engineSha256: sha256(engineBytes), compiledJsSha256: compiledSourceSha256,
    vectorsSha256: sha256(vectorBytes)};
  if (requireCertificate) {
    const proof = JSON.parse(readFileSync(join(directory, 'provenance.json')));
    for (const [key, value] of Object.entries(result)) {
      if (proof[key] !== value) throw new Error(`Scheduler certificate mismatch: ${key}`);
    }
  }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const result = await verifyArtifact(resolve(process.argv[2] || 'build/scheduler'));
  console.log(`${result.matched}/${result.vectors} vectors matched (100%); exact due dates, floats <= 1e-9`);
}
