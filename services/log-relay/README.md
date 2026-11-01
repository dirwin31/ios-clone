# Discord report relay

The iOS diagnostics screen signs in with Discord using OAuth identify and PKCE, previews the report, and sends it to this Worker. The forum webhook and Discord client secret stay in Worker secrets. No bot or domain migration is required.

## Deployment

Use `wrangler deploy` in this directory. Required secrets:

- DISCORD_CLIENT_ID
- DISCORD_CLIENT_SECRET
- DISCORD_WEBHOOK_URL (a webhook for the destination forum)
- DISCORD_PRIVATE_WEBHOOK_URL (a webhook for a separate private forum or text channel)

Register `https://starpilot-log-relay.nathan-g-hubbard.workers.dev/auth/discord/callback` as the Discord OAuth redirect. Optional `FORUM_TAG_IDS` is a comma-separated list of existing forum tag IDs (up to five). Without it, reports have no automatic tags; required forum tags must be configured before use.

`GET /` reports the deployed version. `POST /v1/logs` requires an OAuth access token issued to this Discord application. The test-token endpoint is removed.

## Delivery and privacy

Diagnostics are attached only to the private webhook message. The public forum receives the title, description, reporter mention, and a link to that private message; it receives no diagnostics attachment. Both destinations must be configured and distinct, with no public fallback. The reporter can review them and explicitly submits the report. Access to diagnostics is controlled by the private channel permissions; the public link does not grant access. A thread link is returned to the phone; this does not automatically join the reporter to the server or thread.

A Durable Object per Discord user records report references and delivery results for seven days, with a five-report hourly limit. It does not store diagnostics or OAuth credentials. An ambiguous send at either destination is not automatically repeated. Definite Discord rejections (4xx except request timeout) can be retried with the same unchanged report. A confirmed private upload is retained by message link so a rejected public post resumes without uploading diagnostics again. Network failures, timeouts, malformed confirmations and server errors remain unconfirmed to prevent duplicates. Successful delivery and its dropdown thread entry are saved atomically. The dropdown returns the newest 100 saved threads. The phone saves the pending report with file protection, excluded from backups, and only permits retry under the same Discord account for six days. The user can discard it after checking Discord. Tokens use the iOS Keychain.

Worker request logging is disabled to avoid retaining OAuth callback query strings. Do not add tokens, webhook URLs, or diagnostics to console logs.

## Checks

Run `node --test worker.test.mjs`. These use mocked Discord responses; verify real sign-in, posting, attachment, and opening the forum on a device before announcing end-to-end success.

Reports accept up to 16 MiB of encoded JSON; other endpoints remain limited to 1 MiB. Updated iOS clients fit oversized captures before preview/submission, removing older routine events before failures and marking omissions. Pending retries retain their original capture.

Private diagnostics destination is a forum: `DISCORD_PRIVATE_FORUM=true` creates a private thread for each report and links to its confirmed message. Set it to `false` for a normal private text channel. Public report follow-ups still use the existing public thread.

## Targeted build-ready notifications

Tell the release operator which report(s) a build addresses. The operator registers
an explicit selection in the Cloudflare `BUILD_NOTIFICATIONS` JSON text binding:

```json
[{"userID":"DISCORD_USER_ID","reference":"REPORT_UUID","version":"1.0.3","build":"79","ready":false,"message":"Please test the connection again and reply here with the result."}]
```

Use actual IDs; placeholders fail validation. This is server configuration, not
personalization embedded in the iOS app. Every entry selects one reporter's saved
report reference, which resolves to that account's existing public thread. The
same build may select several reports, or none. Never enumerate open reports to
choose recipients. The authenticated Cloudflare administration interface is the
only way to register selections; there is no public send endpoint.

Write each entry's `message` specifically for the selected report. Include only
changes that address that reported issue, relevant diagnostic improvements, and
what that reporter should retest. Never copy the full build changelog or include
unrelated features, fixes, or other requests from the maintainer. When one build
addresses several reports, write a separate relevant message for each thread.
Check the message against the original report before setting `ready:true`; if a
change's relevance is unclear, omit it. Describe unverified fixes as changes to
test, not a guarantee that the reporter's problem is resolved. The notifier uses
only this per-report message and does not append general release notes.

First leave `ready:false`. Verify `/release-status` shows `pending`, then verify
the selected milestone: `stage:"archived"` requires a successful Apple archive;
omitting stage (or `stage:"testflight"`) requires availability to the recipient's TestFlight group. Archived notices explicitly say access may still require
processing, review, or group assignment.
Only then set `ready:true` in the binding. This readiness step is performed by the
release operator; Apple webhooks are not configured. A five-minute Cron Trigger
sends selected ready notifications. New schedules can take time to propagate.
`GET /release-status` only reads status, without revealing reporter IDs or thread
links. Confirm `sent` before announcing delivery. Remove completed selections
from the binding when preparing later builds; stored deduplication survives.
Preserve this binding on deployments (inherit it through the Cloudflare API).

Every notification mentions the reporter **and REPORT_MAINTAINER_ID**, with all
other mention parsing disabled. It posts only in the selected public thread,
never in private diagnostics or the forum generally. Followers' ordinary Discord
notifications still depend on their settings. A build/version/thread key prevents
duplicate posts, including concurrent scheduled invocations and restarts. A 429
waits before retry; all uncertain deliveries stop for manual investigation.
Do not delete the deduplication record to retry an uncertain send.

Report-to-thread references and notification receipts persist without diagnostic
contents or tokens. The original seven-day retry receipt expiry is unchanged.
Older reports can resolve from their unexpired receipt; missing older mappings
must be investigated rather than guessing the destination.
