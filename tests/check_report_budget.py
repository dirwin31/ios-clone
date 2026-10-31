from pathlib import Path
import subprocess, tempfile
source = Path('GalaxyBluetooth/DiscordReports.swift').read_text()
helper = source[source.index('enum DiagnosticReportBudget'):source.index('private struct PendingDiscordReport')]
probe = 'import Foundation\n' + helper + r'''
let small = "normal diagnostics"
precondition(DiagnosticReportBudget.fit(small) == small)
let budget = 128 * 1024
let failure = "2026-10-31T20:00:00Z GET /api/device/state → 502, important evidence"
let routine = (0..<1000).map { "2026-10-31T19:00:00Z request \($0) " + String(repeating: "\\\"🛰", count: 100) }.joined(separator: "\n")
let capture = "Connection snapshot\n" + failure + "\n" + routine + "\nGalaxy snapshot\n"
let fitted = DiagnosticReportBudget.fit(capture, maximumBytes: budget)
let fittedSize = try JSONEncoder().encode(fitted).count
precondition(fittedSize <= budget - 64 * 1024)
precondition(fitted.contains(failure))
precondition(fitted.contains("Connection snapshot"))
precondition(fitted.contains("Galaxy snapshot"))
precondition(fitted.contains("omitted"))
let fallback = DiagnosticReportBudget.fit(String(repeating: "🛰\\\"", count: 100000), maximumBytes: budget)
let fallbackSize = try JSONEncoder().encode(fallback).count
precondition(fallbackSize <= budget - 64 * 1024)
precondition(fallback.contains("snapshot shortened"))
print("Report budget: unchanged small reports, escaped Unicode size, failure retention, section headers, and oversized snapshot passed")
'''
with tempfile.TemporaryDirectory() as folder:
    p = Path(folder)
    (p/'probe.swift').write_text(probe)
    subprocess.run(['swiftc', '-module-cache-path', str(p/'cache'), str(p/'probe.swift'), '-o', str(p/'probe')], check=True)
    subprocess.run([str(p/'probe')], check=True)
