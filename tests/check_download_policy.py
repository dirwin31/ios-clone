from pathlib import Path
import subprocess, tempfile
source = Path('GalaxyBluetooth/GalaxyWebView.swift').read_text()
start = source.index('        private func isLocal(')
end = source.index('\n        func userContentController', start)
methods = source[start:end].replace('private func', 'func')
probe = 'import Foundation\nstruct Policy { let origin: URL; let requestKey: String\n' + methods + '\n}\n' + r'''
let policy = Policy(origin: URL(string: "http://127.0.0.1:12345")!, requestKey: "synthetic-key")
for path in ["/api/settings/backup", "/data/file.json"] {
 let url = URL(string: "http://127.0.0.1:12345" + path)!
 precondition(policy.isLocal(url))
 var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data("payload".utf8)
 let authorized = policy.authorized(request)
 precondition(authorized.value(forHTTPHeaderField: "X-Galaxy-Local") == "synthetic-key")
 precondition(authorized.httpBody == request.httpBody && authorized.httpMethod == "POST")
}
for url in ["https://127.0.0.1:12345/api/backup", "http://127.0.0.1:54321/api/backup", "https://example.com/", "http://127.0.0.1.example.com:12345/"] {
 precondition(!policy.isLocal(URL(string:url)!))
}
print("Galaxy downloads: same-origin authorization, request preservation and redirect boundaries passed")
'''
with tempfile.TemporaryDirectory() as folder:
 p=Path(folder);(p/'probe.swift').write_text(probe)
 subprocess.run(['swiftc','-module-cache-path',str(p/'cache'),str(p/'probe.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
