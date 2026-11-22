import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {runInNewContext} from 'node:vm'

const swift = readFileSync(new URL('../GalaxyBluetooth/LoopbackServer.swift', import.meta.url), 'utf8')
const adapter = swift.match(/static let nativeCameraPlaybackScript = #"""\r?\n([\s\S]*?)\r?\n    """#/)[1]
const origin = 'http://127.0.0.1:49321'
const src = './api/recordings/media/segment/fcamera'
const video = {
  events: [], after() {}, load() {}, removeAttribute() { delete this.src },
  dispatchEvent(event) { this.events.push(event.type) },
}
const component = {template: '<video :src="url"></video>'}
let serve
const context = {
  window: {__galaxyNative: true}, CameraViewer: component, location: {origin},
  document: {baseURI: origin + '/', createElement: () => ({setAttribute() {}, remove() {}})},
  URL, Blob, Event, AbortController, DOMException, fetch: (...args) => serve(...args),
}
runInNewContext(adapter, context)
assert.match(component.template, /v-recording-src="url"/)
assert.doesNotMatch(component.template, /\s:src=/)
const player = component.directives.recordingSrc
const headers = {'Content-Type': 'video/mp4'}
const bytes = Buffer.alloc(9 * 1024 * 1024 + 37)
for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251
let requests = 0
serve = (url, options) => {
  assert.equal(url.href, origin + src.slice(1))
  assert.equal(options.redirect, 'error')
  const [, start, requestedEnd] = /^bytes=(\d+)-(\d+)$/.exec(options.headers.Range).map(Number)
  const end = Math.min(requestedEnd, bytes.length - 1)
  assert.equal(start, requests++ * 2 * 1024 * 1024)
  return new Response(bytes.subarray(start, end + 1), {
    status: 206, headers: {...headers, 'Content-Range': 'bytes ' + start + '-' + end + '/' + bytes.length},
  })
}
await player.mounted(video, {value: src})
assert.equal(requests, 5)
const recording = video.src
assert.match(recording, /^blob:/)
assert.deepEqual(Buffer.from(await (await fetch(recording)).arrayBuffer()), bytes)
player.beforeUnmount(video)
await assert.rejects(fetch(recording))

let finishOld, oldSignal
serve = (_url, {signal}) => {
  oldSignal = signal
  return new Promise(resolve => { finishOld = resolve })
}
const old = player.mounted(video, {value: src})
serve = () => new Response('next segment', {headers})
await player.mounted(video, {value: src.replace('segment', 'next')})
assert.ok(oldSignal.aborted)
const next = video.src
finishOld(new Response('late', {headers}))
await old
assert.equal(video.src, next)
assert.equal(await (await fetch(next)).text(), 'next segment')
assert.deepEqual(video.events, [])
player.beforeUnmount(video)

for (const [status, range, body] of [[206, 'bytes 1-2/3', 'xx'], [206, 'bytes 0-2/3', 'xx'],
                                    [206, 'bytes 0-2/536870913', 'xxx'], [403, null, 'forbidden']]) {
  serve = () => new Response(body, {status, headers: range ? {...headers, 'Content-Range': range} : headers})
  await player.mounted(video, {value: src})
  assert.equal(video.src, undefined)
  assert.deepEqual(video.events.splice(0), ['error'])
}
let foreignRequests = 0
serve = () => { foreignRequests++; return new Response('foreign', {headers}) }
await player.mounted(video, {value: 'https://example.invalid/api/recordings/media/segment/fcamera'})
assert.equal(foreignRequests, 0)
assert.deepEqual(video.events, ['error'])
player.beforeUnmount(video)
console.log('Route footage ranges, complete bytes, stale loads, cleanup and errors passed')
