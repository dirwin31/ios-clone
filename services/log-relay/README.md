# Discord report relay

The iOS diagnostics screen signs in with Discord using OAuth identify and PKCE, previews the report, and sends it to this Worker. The forum webhook and Discord client secret stay in Worker secrets. No bot or domain migration is required.

## Deployment

Use `wrangler deploy` in this directory. Required secrets:

- DISCORD_CLIENT_ID
- DISCORD_CLIENT_SECRET
- DISCORD_WEBHOOK_URL (a webhook for the destination forum)
- DISCORD_PRIVATE_WEBHOOK_URL (a webhook for a separate private text channel)

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
