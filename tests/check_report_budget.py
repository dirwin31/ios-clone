from pathlib import Path
import subprocess, tempfile
source = Path('GalaxyBluetooth/DiscordReports.swift').read_text(encoding='utf-8')
helper = source[source.index('enum DiagnosticReportBudget'):source.index('private struct PendingDiscordReport')]
probe = 'import Foundation\n' + helper + r'''
let provenance = "Build distribution: TestFlight / sandbox (verified sandbox app transaction)"
let withDistribution = SubmissionDiagnostics.capture(logs: { provenance + "\n" + String(repeating: "x", count: 200000) }, maximumBytes: 100000)
precondition(withDistribution.hasPrefix("StarPilot report submission"))
precondition(withDistribution.contains(provenance), "Build source must survive oversized snapshot trimming")
let unknownDistribution = SubmissionDiagnostics.capture(logs: { "no source available" })
precondition(unknownDistribution.contains("Build distribution: Unknown"))
let small = "normal diagnostics"
precondition(DiagnosticReportBudget.fit(small) == small)
var captureCount = 0
var liveLogs = "Latest connection event"
let submitted = SubmissionDiagnostics.capture(logs: { captureCount += 1; return liveLogs },
    now: Date(timeIntervalSince1970: 0), version: "1.0.5", build: "87")
precondition(captureCount == 1)
precondition(submitted.contains("Installed app at Send: 1.0.5 (87)"))
precondition(submitted.contains("Captured at Send (UTC): 1970-01-01T00:00:00Z"))
precondition(submitted.contains(liveLogs))
liveLogs = "Later connection event"
precondition(!submitted.contains(liveLogs), "Retry snapshot must remain immutable")
let next = SubmissionDiagnostics.capture(logs: { captureCount += 1; return liveLogs }, version: "1.0.6", build: "88")
precondition(captureCount == 2 && next.contains(liveLogs) && next.contains("1.0.6 (88)"))
precondition(SubmissionDiagnostics.capture(logs: { "  \n" }).isEmpty)
let oversizedSubmission = SubmissionDiagnostics.capture(logs: { String(repeating: "x", count: 200000) },
    version: "1.0.5", build: "87", maximumBytes: 128 * 1024)
precondition(oversizedSubmission.hasPrefix("StarPilot report submission\nInstalled app at Send: 1.0.5 (87)"))
let submissionSize = try JSONEncoder().encode(oversizedSubmission).count
precondition(submissionSize < 64 * 1024)
let routineMessages = [
    "Request completed: HTTP 200; cancelled=false",
    "Upload finished: HTTP 204; consecutive failures=0; cancelled=false",
    "LAN probe finished; failed=false; disconnected=false",
    "Health check; errors=0; cancellations=0; timeouts=0; unavailable=false; unconfirmed=false",
    "Request completed; error=nil; failures=0.0; cancelled = FALSE"
]
for message in routineMessages {
    precondition(!DiagnosticReportBudget.isFailure(message), "Routine message misclassified: \(message)")
}
let failureMessages = [
    "Request failed; cancelled=false; consecutive failures=0",
    "Request completed: HTTP 403; cancelled=false",
    "GET /api/device/state → 502",
    "Request timeout", "Request timed out", "Request cancelled", "Request canceled=true",
    "Connection disconnected", "Tunnel unavailable", "Delivery unconfirmed", "Identity did not verify",
    "failed=true", "failures=1", "failures=0.5", "error=network", "cancelled=true",
    "Request completed; cancelled=false; response error: missing session"
]
for message in failureMessages {
    precondition(DiagnosticReportBudget.isFailure(message), "Failure missed: \(message)")
}
let budget = 128 * 1024
// These later successful events saturate the budget. Misclassifying their status
// fields as failures would discard the earlier real error before these polls.
let failure = "2026-10-31T18:00:00Z GET /api/device/state → 502, important evidence"
let routine = (0..<1000).map {
    "2026-10-31T19:00:00Z request \($0) \(routineMessages[$0 % routineMessages.count]) " + String(repeating: "\\\"🛰", count: 100)
}.joined(separator: "\n")
let capture = "Connection snapshot\n" + failure + "\n" + routine + "\nGalaxy snapshot\n"
let fitted = DiagnosticReportBudget.fit(capture, maximumBytes: budget)
let fittedSize = try JSONEncoder().encode(fitted).count
precondition(fittedSize <= budget - 64 * 1024)
precondition(fitted.contains(failure))
precondition(fitted.contains("Connection snapshot"))
precondition(fitted.contains("Galaxy snapshot"))
precondition(fitted.contains("omitted"))
precondition(fitted.contains("HTTP 200"), "The budget should retain some recent routine history too")
let fallback = DiagnosticReportBudget.fit(String(repeating: "🛰\\\"", count: 100000), maximumBytes: budget)
let fallbackSize = try JSONEncoder().encode(fallback).count
precondition(fallbackSize <= budget - 64 * 1024)
precondition(fallback.contains("snapshot shortened"))
print("Report budget: benign status classification, saturation retaining earlier failures, escaped Unicode size, section headers, and oversized snapshot passed")
'''
with tempfile.TemporaryDirectory() as folder:
    p = Path(folder)
    (p/'probe.swift').write_text(probe, encoding='utf-8')
    subprocess.run(['swiftc', '-module-cache-path', str(p/'cache'), str(p/'probe.swift'), '-o', str(p/'probe')], check=True)
    subprocess.run([str(p/'probe')], check=True)
