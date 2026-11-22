---
title: GATT kept off classic Bluetooth so iPhones use LE
author: Danny
date: 2026-11-19
branch: notifications-over-ble
cost: { minutes: 29, tokens: 227237 }
touches:
  - GalaxyBluetooth/BluetoothTransport.swift
---

## Decided
- GATT stays off classic Bluetooth: an LD_PRELOAD shim on bluetoothd (no listen on BR/EDR PSM 31) plus deleting ATT SDP records. bootstrap applies it once per boot and the bridge unit's root ExecStartPost strips records after each start.
- The bridge survives a refused advertisement and retries it, since iPhones keep an LE link up for ANCS.
## Tried and ruled out
- Overrides in /etc (read-only on AGNOS) and the shim under /data (bluetoothd's ProtectSystem/ProtectHome hide it); /run works.
## Watch out
- The kernel refuses connectable advertising while any LE link is up on this controller (MGMT Add Advertising 0x03, no HCI sent).
- iOS caches SDP: after first applying it, the phone needs one classic reconnect.
- The bootstrap test forbids the word install in commands; the helper uses apply.
