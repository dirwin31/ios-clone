import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const swift = readFileSync('GalaxyBluetooth/GalaxyWebView.swift', 'utf8');
const script = swift.split('// BEGIN AUTHENTICATED SENTRY IMAGES')[1].split('// END AUTHENTICATED SENTRY IMAGES')[0];
const requests = [], revoked = [], events = [], images = [], diagnostics = [];
let observe, pagehide, blobID = 0;
class Image {
  constructor(src) { this.src = src; this.isConnected = true; this.listeners = {}; this.naturalWidth = 640; this.naturalHeight = 480; images.push(this); }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  removeEventListener(name, fn) { if (this.listeners[name] === fn) delete this.listeners[name]; }
  getAttribute() { return this.src; }
  setAttribute(_, value) { this.src = value; }
  matches(selector) { return selector === 'img'; }
  querySelectorAll() { return []; }
}
class TestURL extends URL {
  static createObjectURL() { return 'blob:test/' + ++blobID; }
  static revokeObjectURL(url) { revoked.push(url); }
}
vm.runInNewContext(script, {
  URL: TestURL, AbortController, Map,
  location: {href: 'http://127.0.0.1:1234/', origin: 'http://127.0.0.1:1234'},
  key: 'test-secret', emit: (...args) => events.push(args),
  sentryLog: (stage, values) => diagnostics.push({stage, ...values}),
  originalFetch: (url, options) => new Promise(resolve => requests.push({url, options, resolve})),
  MutationObserver: class { constructor(callback) { observe = callback; } observe() {} },
  document: {readyState: 'complete', documentElement: {}, querySelectorAll: () => images},
  window: {addEventListener: (event, callback) => { if (event === 'pagehide') pagehide = callback; }}
});
const added = img => observe([{type: 'childList', addedNodes: [img]}]);
const changed = img => observe([{type: 'attributes', target: img}]);
const flush = () => new Promise(resolve => setImmediate(resolve));
const response = (type = 'image/jpeg', size = 10) => ({ok: true, status: 200, blob: async () => ({type, size})});

const img = new Image('./api/sentry/image/event/road'); added(img);
assert.equal(requests.length, 1);
assert.equal(requests[0].options.headers['X-Galaxy-Local'], 'test-secret');
assert.equal(requests[0].options.redirect, 'error');
requests[0].resolve(response()); await flush();
assert.equal(img.src, 'blob:test/1'); changed(img);
assert.ok(!diagnostics.some(x => x.stage === 'image-rendered'), 'download alone does not prove rendering');
img.listeners.load();
assert.ok(diagnostics.some(x => x.stage === 'image-rendered' && x.width === 640 && x.height === 480));
assert.equal(requests.length, 1, 'blob replacement must not refetch');
img.src = './api/sentry/image/event/driver'; changed(img);
assert.deepEqual(revoked, ['blob:test/1']);
assert.equal(requests.length, 2);
img.src = './api/sentry/image/new/road'; changed(img);
assert.equal(requests[1].options.signal.aborted, true);
requests[1].resolve(response()); await flush();
assert.equal(img.src, './api/sentry/image/new/road', 'stale response must not replace a newer image');
requests[2].resolve(response()); await flush();
assert.equal(img.src, 'blob:test/2');
img.listeners.error();
assert.ok(diagnostics.some(x => x.stage === 'image-decode-failed'));
img.isConnected = false; observe([{type: 'childList', addedNodes: []}]);
assert.deepEqual(img.listeners, {}, 'removed images must release diagnostic listeners');
assert.ok(revoked.includes('blob:test/2'));
for (const src of ['https://example.com/api/sentry/image/x/road', '/logo.svg', '/api/settings', 'blob:other']) added(new Image(src));
assert.equal(requests.length, 3, 'never send the app key to other origins or unrelated images');
const bad = new Image('/api/sentry/image/bad/road'); added(bad);
requests[3].resolve(response('text/html')); await flush();
assert.equal(bad.src, '/api/sentry/image/bad/road');
assert.equal(events.length, 1);
const denied = new Image('/api/sentry/image/denied/road'); added(denied);
requests[4].resolve({ok: false, status: 403}); await flush();
assert.equal(events.length, 2);
assert.ok(diagnostics.some(x => x.stage === 'image-http' && x.http === 403));
assert.ok(diagnostics.some(x => x.stage === 'image-invalid' && x.bytes === 10));
assert.ok(!JSON.stringify(diagnostics).includes('test-secret'));
const pending = new Image('/api/sentry/image/pending/road'); added(pending);
pagehide();
assert.equal(requests[5].options.signal.aborted, true);
assert.ok(readFileSync('GalaxyBluetooth/LoopbackServer.swift', 'utf8').includes('guard request.headers["x-galaxy-local"] == localSecret'));
console.log('Sentry images: authorization, origin boundaries, stale responses, failures, and cleanup passed');
