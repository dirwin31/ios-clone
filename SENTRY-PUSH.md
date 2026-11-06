# Sentry phone alerts

This app uses Apple Push Notification service directly. No Firebase dependency is required for iOS. It uses the existing Galaxy phone-subscription API and reports the new per-comma relay enrollment status. Hosted v2 delivery requires the companion StarPilot and Worker PRs; old private v1 pilots remain compatible. Nate can use his existing Apple developer membership.

## Maintainer setup

1. Enable Push Notifications for `link.galaxy.bluetooth.natehuby76` in your Apple developer account and regenerate provisioning profiles.
2. Give the relay operator an APNs signing key (`.p8`), its Key ID and your Team ID over a private channel. Use a key scoped to this app and the needed APNs environments. Never include the key in the app, comma, Git, or a PR.
3. Build with the app's existing bundle ID. Debug has `APS_ENVIRONMENT=development`, Release has `APS_ENVIRONMENT=production`. The same setting supplies the entitlement and `SentryAPNsEnvironment` in Info.plist. Use Release for TestFlight/App Store. Verify the final signed entitlement and Info.plist agree when customizing archive/export settings.
4. The relay host stores the key, Key ID and Team ID as Worker secrets ([HOSTING.md](https://github.com/dirwin31/StarPilotAndroid/blob/sentry-cloudflare/push-relay/HOSTING.md) step 5). The Worker's `IOS_APP_IDS` already includes this bundle ID; keep it there.

## User setup

Install the StarPilot enrollment PR. In Galaxy → Sentry → Galaxy app phones, tap Enable alerts. The relay address comes from the StarPilot release configuration; there is no URL or code to enter. The app requests notification permission, registers this phone and enrolls comma automatically. Never enter the operator admin key or an Apple signing key. Then enable Sentry phone alerts in the app's Settings or Galaxy's Sentry page, allow notifications, connect to comma, and send a test. Configure the relay once per comma; each phone registers separately.

Comma needs internet while parked, and the iPhone needs internet to receive alerts. A push contains event metadata, not camera images. Tapping it opens the Sentry events page after the app connects to comma. This implementation does not attach photos or poll in the background. Apple controls delivery timing; acceptance by the relay is not a display receipt.

Disabling unregisters from APNs and removes the comma subscription when connected. If disconnected, removal is retried on reconnect. Token rotation removes the old subscription before registering the new one. Subscriptions are tracked per comma identity; after reinstalling the app, remove obsolete phones from Galaxy if they remain listed. iOS may display duplicates if comma retries after an interrupted response; APNs collapses pending copies by event ID.

## Relay contract

The app registers through the existing authenticated transport:

```json
{"action":"appSubscribe","token":"apns.production.<hex-device-token>","appId":"link.galaxy.bluetooth.natehuby76","label":"iPhone"}
```

Development builds use `apns.sandbox.<hex-device-token>`. Comma treats this as an opaque subscription token and registers its destination under the comma credential and forwards the six-field event body to `<base-url>/v2/sentry`. Legacy private pilots use `/v1/sentry`. The phone never stores the comma credential. The Worker selects the corresponding APNs server and sends a visible alert with `type=sentry` and the event ID. Only a confirmed APNs `Unregistered` response returns 410; wrong credentials/environment/topic return 502, preserving the subscription.

## Validation

Run `python3 tests/check_sentry_push.py` from this directory for registration, token rotation, retry, disable/reconnect and test-request regressions. The harness compiles the production registration model with a fake comma transport and application lifecycle.

Build in Xcode and test on physical iPhones with development and TestFlight signatures. Verify background/locked-screen receipt, tapping while disconnected, notification permission denial, relay outage, token rotation and disable/re-enable. No Apple credentials or live push delivery are included in the automated tests.

Hosting: https://github.com/dirwin31/StarPilotAndroid/blob/sentry-cloudflare/push-relay/HOSTING.md

Provider setup and launch checklist: https://github.com/dirwin31/StarPilotAndroid/blob/sentry-cloudflare/push-relay/SETUP.md

StarPilot enrollment: https://github.com/dirwin31/openpilot/pull/18

Automatic enrollment requires the operator to deploy the Worker and the StarPilot maintainer to set DEFAULT_RELAY_URL once before release. Until then the app reports that hosting is not configured. Existing enabled phones are not silently opted into a new relay; the user must enable alerts.
