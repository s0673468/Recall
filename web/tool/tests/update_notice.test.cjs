const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../../update_notice.js'), 'utf8');

function events(fields = {}) {
  const listeners = new Map();
  return Object.assign(fields, {
    addEventListener(type, callback) {
      const callbacks = listeners.get(type) || [];
      callbacks.push(callback);
      listeners.set(type, callbacks);
    },
    fire(type) {
      for (const callback of listeners.get(type) || []) callback();
    },
    count(type) { return (listeners.get(type) || []).length; },
  });
}

function page({ version = 'a'.repeat(40), controlled = true, elements = true } = {}) {
  const notice = { hidden: true };
  const splash = { textContent: '' };
  const dismiss = events();
  const nodes = {
    'recall-update-notice': notice,
    'recall-splash-version': splash,
    'recall-dismiss-update': dismiss,
  };
  const forbid = () => { throw new Error('Update notice must only inform'); };
  const window = { location: { reload: forbid } };
  const navigator = { serviceWorker: { controller: controlled ? {} : null } };
  Object.defineProperties(window, {
    localStorage: { get: forbid },
    sessionStorage: { get: forbid },
    indexedDB: { get: forbid },
    caches: { get: forbid },
  });
  vm.runInNewContext(source, {
    window, navigator,
    document: {
      querySelector: () => version == null ? null : { content: version },
      getElementById: (id) => elements ? nodes[id] : null,
    },
  });
  return { window, navigator, notice, splash, dismiss };
}

test('startup labels the HTML build and safely handles local/unstamped shells', () => {
  assert.equal(page().splash.textContent, 'Website build aaaaaaa');
  for (const version of [null, '__RECALL_BUILD__', 'bad <build>', 'a'.repeat(41)]) {
    assert.equal(page({ version }).splash.textContent, 'Development build');
  }
});

test('an already waiting update is visible on a controlled page', () => {
  const p = page();
  const registration = events({ waiting: {} });
  p.window.recallWatchWebUpdates(registration);
  assert.equal(p.notice.hidden, false);
});

test('first-install offline support does not show an update notice', () => {
  const p = page({ controlled: false });
  p.window.recallWatchWebUpdates(events({ waiting: {} }));
  assert.equal(p.notice.hidden, true);
});

test('an installation already in flight becomes a waiting update', () => {
  const p = page();
  const worker = events({ state: 'installing' });
  const registration = events({ installing: worker, waiting: null });
  p.window.recallWatchWebUpdates(registration);
  assert.equal(p.notice.hidden, true);
  worker.state = 'installed';
  registration.waiting = worker;
  worker.fire('statechange');
  assert.equal(p.notice.hidden, false);
});

test('an update found after registration is watched without duplicate listeners', () => {
  const p = page();
  const registration = events({ installing: null, waiting: null });
  p.window.recallWatchWebUpdates(registration);
  const worker = events();
  registration.installing = worker;
  registration.fire('updatefound');
  registration.fire('updatefound');
  assert.equal(worker.count('statechange'), 1);
  registration.waiting = worker;
  worker.fire('statechange');
  assert.equal(p.notice.hidden, false);
});

test('a failed download never announces that the update is ready', () => {
  const p = page();
  const worker = events({ state: 'installing' });
  const registration = events({ installing: worker, waiting: null });
  p.window.recallWatchWebUpdates(registration);
  worker.state = 'redundant';
  worker.fire('statechange');
  assert.equal(p.notice.hidden, true);
});

test('dismissal lasts for this session even if another worker arrives', () => {
  const p = page();
  const worker = events();
  const registration = events({ installing: worker, waiting: worker });
  p.window.recallWatchWebUpdates(registration);
  p.dismiss.fire('click');
  worker.fire('statechange');
  registration.installing = events();
  registration.waiting = registration.installing;
  registration.fire('updatefound');
  assert.equal(p.notice.hidden, true);
});

test('missing optional shell elements do not break service-worker registration', () => {
  const p = page({ elements: false });
  assert.doesNotThrow(() => p.window.recallWatchWebUpdates(events({ waiting: {} })));
});
