# Send a place from Google Maps, Apple Maps or Waze

Waze destination links with `ll` coordinates or a `q` address are supported. HTTPS short links are followed only within Waze's allowed hosts, for at most five redirects. Opaque links that do not resolve to an address or coordinates show an explanation; Waze favorites such as Home/Work are not read from your Waze account. This shares a destination, not Waze's route, traffic reports, or turn instructions. Comma uses its configured navigation provider.

A new share replaces the previous saved destination, including when the new destination is sent immediately. Saved destinations are bound to the comma selected when sharing, expire after 12 hours, and are not delivered to a different comma. Older saved entries without a device identity are discarded. A share already accepted by comma cannot be recalled; the newest share sends its replacement destination.

Release validation still requires registering the share App ID and App Group, a signed iPhone build, and testing sharing over local Wi-Fi, tunnel and Bluetooth fallback. The Swift sharing regressions run in `ci_post_clone.sh` on macOS.

In Waze, Google Maps, Apple Maps or Safari, open a place, tap **Share**, then **StarPilot**. The share card shows whether comma started a route or the destination was saved for later.

The first time, StarPilot may not be in the row of app icons. Scroll the row to the end, tap **More**, turn on **StarPilot** and, if you like, drag it up into Favorites.

## How it reaches comma

The share sheet tries the saved home-network address first, then the Galaxy tunnel when it is signed in. Navigation is turned on if it was off. comma reads the place from the link, or looks up its name and address when the link has no coordinates. It needs a map key set up in Galaxy's Navigation settings.

When the share sheet can't reach your comma, it can save the destination for delivery. StarPilot BT retries while running when it connects to your comma, including over Bluetooth. If iOS has paused the app, open it while connected to send the saved place. A background delivery can post a notification if notifications are allowed. Only the latest place is kept, and a saved place expires after 12 hours.

When comma finds no single match, StarPilot BT opens Galaxy's Navigation page with the place's search results the next time you open the app. If comma answers with a problem, such as a missing map key, the card shows comma's message.

The phone resolves supported Google and Waze short links over HTTPS and only follows redirects to allowed hosts for the same provider.

The share sheet uses the app's Local Network permission. Open StarPilot BT once on the home network and allow Local Network access, or the share sheet can only use the tunnel.

## Siri and Shortcuts (optional)

StarPilot BT also adds a **Send to StarPilot** action to Shortcuts and Siri. It works like the share sheet and saves the place when comma is out of reach. To use it from an app whose share sheet doesn't offer StarPilot:

1. Open **Shortcuts** and tap **+**.
2. Tap the shortcut's name, choose **Rename** and enter `Send to StarPilot`.
3. Tap the **ⓘ** (Details), turn on **Show in Share Sheet**, and set the accepted types to **URLs** and **Text**. Tap **Done**.
4. Add the app action **StarPilot BT › Send to StarPilot** and set its **Place** to **Shortcut Input**.

Opening `starpilot://share?text=<URL-encoded shared text>` does the same from inside the app.
