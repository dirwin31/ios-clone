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

# Exercise the same file writer used by the web view with a range-capable export.
writer = source[source.index('        private static func writeReplay'):source.index('        private func track(_ download')]
writer = writer.replace('private static func', 'static func')
fixture = r"""
import Foundation
enum Wire { static let maxBody = 1024 * 1024 }
enum BoundedHTTP {
    static func load(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let size = 53_200_001
        let range = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-")
        let start = Int(range[0])!, end = min(Int(range[1])!, size - 1)
        precondition(start % limit == 0 && end - start < limit)
        let headers = ["Content-Type": "video/mp4", "Content-Range": "bytes \(start)-\(end)/\(size)"]
        let count = end - start + (url.path == "/broken" && start > 0 ? 0 : 1)
        return (Data(repeating: UInt8(start / limit), count: count),
                HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: headers)!)
    }
}
@main struct Check {
""" + writer + r"""
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = URLRequest(url: URL(string: "http://localhost/export")!)
        let url = try await writeReplay(request, in: folder, chunkLimit: { 8 * Wire.maxBody })
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        precondition(data.count == 53_200_001)
        for start in stride(from: 0, to: data.count, by: 8_388_608) {
            precondition(data[start] == UInt8(start / 8_388_608))
            precondition(data[min(start + 8_388_607, data.count - 1)] == data[start])
        }
        do {
            _ = try await writeReplay(URLRequest(url: URL(string: "http://localhost/broken")!), in: folder, chunkLimit: { 2 * Wire.maxBody })
            fatalError("accepted incomplete range")
        } catch URLError.badServerResponse {}
    }
}
"""
with tempfile.TemporaryDirectory() as folder:
    p = Path(folder)
    (p/'export.swift').write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(p/'cache'), str(p/'export.swift'), '-o', str(p/'export')], check=True)
    subprocess.run([str(p/'export')], check=True)
