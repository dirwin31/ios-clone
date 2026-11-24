import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {runInNewContext} from 'node:vm'

const source = readFileSync(new URL('../GalaxyBluetooth/GalaxyWebView.swift', import.meta.url), 'utf8')
const start = source.indexOf('const phoneAppearance =')
const end = source.indexOf("document.addEventListener('click'", start)
assert(start > 0 && end > start)
for (const ready of [false, true]) {
  let onReady
  const document = {
    documentElement: ready ? {dataset: {}} : null,
    addEventListener(name, handler) {
      assert.equal(name, 'DOMContentLoaded')
      onReady = handler
    },
  }
  const preferences = new Map()
  runInNewContext(source.slice(start, end), {
    document, window: {matchMedia: () => ({matches: true})},
    localStorage: {setItem: (key, value) => preferences.set(key, value)},
  })
  if (!ready) {
    document.documentElement = {dataset: {}}
    onReady()
  }
  assert.equal(document.documentElement.dataset.theme, 'dark')
  assert.equal(preferences.get('galaxy-preview-theme'), 'dark')
}
console.log('Galaxy theme setup survives early document injection')
