from pathlib import Path
for name in ['LANDiscovery.swift', 'Info.plist']:
  value = (Path('GalaxyBluetooth') / name).read_text()
  assert '_sp-galaxy._tcp' in value and '_starpilot-galaxy._tcp' not in value
for name in ['CarPlaySceneDelegate.swift', 'CarPlayDashboard.swift', 'GalaxyBluetoothApp.swift', 'GalaxyRootView.swift', 'CompanionChrome.swift', 'ConnectionEventLog.swift', 'NetworkTransport.swift']:
  value = (Path('GalaxyBluetooth') / name).read_text()
  for old in ['/api/params', '/api/stats', '/api/device/status', '/api/personality_profiles', '/api/longitudinal_mode']:
    assert old not in value, (name, old)
for name in ['GalaxyAssetStore.swift', 'LoopbackServer.swift', 'GalaxyBluetoothApp.swift', 'GalaxyRootView.swift']:
  value = (Path('GalaxyBluetooth') / name).read_text()
  assert 'bundledRoot' not in value and 'Resources/Web' not in value and 'raw.githubusercontent.com' not in value, name
assert not Path('GalaxyBluetooth/Resources/Web').exists(), 'Galaxy pages come from comma, never from the app bundle'
settings = Path('GalaxyBluetooth/ConnectionSettingsView.swift').read_text(encoding='utf-8')
assert 'ForEach(discovery.devices) { device in' in settings, 'A single advertised comma also needs a selectable row'
assert 'await model.selectDiscoveredComma(device)' in settings, 'Selection must verify the advertised endpoint'
controller = Path('GalaxyBluetooth/GalaxyBluetoothApp.swift').read_text(encoding='utf-8')
for context in ['Selected comma', 'Automatic LAN verification', 'Bluetooth pairing via LAN']:
  assert f'context: "{context}"' in controller, f'Missing diagnostic context for {context}'
assert 'candidate.onDiagnostic = log' in controller and 'candidate.onEvent = log' in controller
assert 'Automatic selection skipped: Bluetooth key saved without a saved comma identity' in controller
print('LAN contract: discovery service type, endpoint migration and no bundled Galaxy pages passed')
