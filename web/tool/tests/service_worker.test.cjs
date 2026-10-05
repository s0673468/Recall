const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../../sw.js'), 'utf8');
const base = 'https://example.test/Recall/sw.js';

function worker({ cached, failWrite = false, failInstall = false } = {}) {
  const listeners = new Map();
  const stored = new Map();
  const requests = [];
  const response = (body) => ({ ok: true, type: 'basic', body, clone() { return this; } });
  async function fetch(request, options = {}) {
    requests.push(request);
    // Simulate the prior deploy still being fresh in the browser HTTP cache.
    return response((options.cache || request.cache) === 'reload' ? 'new deploy' : 'old deploy');
  }
  const cache = {
    async add(request) {
      if (failInstall && request.url.endsWith('canvaskit.wasm')) throw new Error('mid-deploy 404');
      stored.set(request.url, await fetch(request));
    },
    async match() { return cached; },
    async put(request, value) {
      if (failWrite) throw new Error('quota');
      stored.set(request.url, value);
    },
  };
  const context = vm.createContext({
    URL, Request, Promise, fetch,
    caches: { async open() { return cache; } },
    self: {
      location: { href: base, origin: new URL(base).origin },
      addEventListener(type, handler) { listeners.set(type, handler); },
    },
  });
  vm.runInContext(source, context);
  return {
    stored, requests,
    async install() {
      let completion;
      listeners.get('install')({ waitUntil(value) { completion = value; } });
      await completion;
    },
    async load() { return await context.cacheFirst(new Request(new URL('main.dart.js', base))); },
  };
}

test('new-version installation bypasses a still-fresh previous HTTP deploy', async () => {
  const w = worker();
  await w.install();
  assert.equal(w.stored.get(new URL('./', base).href).body, 'new deploy');
  assert.equal(w.stored.get(new URL('main.dart.js', base).href).body, 'new deploy');
  assert.equal(w.stored.size, 6);
  assert.ok(w.requests.every(request => request.cache === 'reload'));
});

test('an uncached asset also bypasses the old HTTP deploy', async () => {
  const w = worker();
  assert.equal((await w.load()).body, 'new deploy');
  assert.equal(w.stored.get(new URL('main.dart.js', base).href).body, 'new deploy');
});

test('existing version-cache hits remain usable without network access', async () => {
  const cached = { body: 'active session' };
  const w = worker({ cached });
  assert.equal(await w.load(), cached);
  assert.equal(w.requests.length, 0);
});

test('a cache write failure still delivers the fresh network response', async () => {
  assert.equal((await worker({ failWrite: true }).load()).body, 'new deploy');
});

test('a failed precache asset does not discard the successful fresh assets', async () => {
  const w = worker({ failInstall: true });
  await w.install();
  assert.equal(w.stored.size, 5);
  assert.equal(w.stored.get(new URL('./', base).href).body, 'new deploy');
});
