import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const swift = readFileSync('GalaxyBluetooth/GalaxyWebView.swift', 'utf8');
const script = swift.slice(swift.indexOf('          const originalFetch'), swift.indexOf('          const originalOpen'));
const logs = [], requests = [];
let reply;
const window = {
  webkit: {messageHandlers: {galaxyDiagnostics: {postMessage: value => logs.push(value)}}},
  fetch: async request => { requests.push(request); if (reply instanceof Error) throw reply; return reply; }
};
vm.runInNewContext(script, {window, Request, Headers, URL, Date, key: 'private-test-key', local: url => new URL(url).origin === 'http://localhost'});
const flush = () => new Promise(resolve => setImmediate(resolve));
reply = new Response(JSON.stringify({events: [], storageBytes: 0}));
let result = await window.fetch('http://localhost/api/sentry/events');
await flush();
assert.deepEqual(await result.json(), {events: [], storageBytes: 0}, 'diagnostics must not consume the page response');
assert.ok(logs.some(x => x.stage === 'events-result' && x.count === 0 && x.images === 0 && x.bytes === 0));
assert.equal(requests[0].headers.get('X-Galaxy-Local'), 'private-test-key');
reply = new Response(JSON.stringify({events: [{images: ['wide', 'cabin']}], storageBytes: 321, scanIncomplete: true}));
await window.fetch('http://localhost/api/sentry/events'); await flush();
assert.ok(logs.some(x => x.stage === 'events-result' && x.count === 1 && x.images === 2 && x.incomplete));
reply = new Response('unauthorized', {status: 401});
await window.fetch('http://localhost/api/sentry/events'); await flush();
assert.ok(logs.some(x => x.stage === 'events-http' && x.http === 401));
assert.ok(logs.some(x => x.stage === 'events-invalid'));
reply = new TypeError('network error with sensitive server detail');
await assert.rejects(window.fetch('http://localhost/api/sentry/events'));
assert.ok(logs.some(x => x.stage === 'events-network-failed'));
const before = logs.length;
reply = new Response('{}');
await window.fetch('http://example.com/api/sentry/events');
assert.equal(logs.length, before);
assert.equal(requests.at(-1).headers.get('X-Galaxy-Local'), null);
assert.ok(!JSON.stringify(logs).match(/private-test-key|sensitive server detail|unauthorized/));
console.log('Sentry event diagnostics: empty and populated lists, invalid response, network failure, privacy and response preservation passed');
