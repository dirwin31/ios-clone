# Send a place from Google Maps or Apple Maps

In Google Maps, Apple Maps or Safari, open a place, tap **Share**, then **StarPilot**. comma sets the destination and starts the route. The app does not open; a small card shows "Sending to comma…" and then "Route to … started on comma."

The first time, StarPilot may not be in the row of app icons. Scroll the row to the end, tap **More**, turn on **StarPilot** and, if you like, drag it up into Favorites.

## How it reaches comma

The share sheet tries the saved home-network address first, then the Galaxy tunnel when it is signed in. Navigation is turned on if it was off. comma reads the place from the link, or looks up its name and address when the link has no coordinates. It needs a map key set up in Galaxy's Navigation settings.

When comma can't be reached (the car is off, or the iPhone reaches comma only over Bluetooth), the card says "Saved. The route starts when your iPhone next connects to comma." StarPilot BT sends the saved place when it next connects over any route, including Bluetooth. That is within seconds while the app is running (open, on CarPlay, sharing GPS or navigating); otherwise iOS keeps it paused, and the place goes out the next time the app wakes or you open it. If the app was in the background it posts a notification when notifications are already allowed. Only the latest place is kept, and a saved place expires after 12 hours.

When comma finds no single match, StarPilot BT opens Galaxy's Navigation page with the place's search results the next time you open the app. If comma answers with a problem, such as a missing map key, the card shows comma's message.

Google's short links (`maps.app.goo.gl`) are followed on the phone, only to Google hosts over HTTPS, because comma may have no route to Google. Nothing else is sent anywhere.

The share sheet uses the app's Local Network permission. Open StarPilot BT once on the home network and allow Local Network access, or the share sheet can only use the tunnel.

## Siri and Shortcuts (optional)

StarPilot BT also adds a **Send to StarPilot** action to Shortcuts and Siri. It works like the share sheet and saves the place when comma is out of reach. To use it from an app whose share sheet doesn't offer StarPilot:

1. Open **Shortcuts** and tap **+**.
2. Tap the shortcut's name, choose **Rename** and enter `Send to StarPilot`.
3. Tap the **ⓘ** (Details), turn on **Show in Share Sheet**, and set the accepted types to **URLs** and **Text**. Tap **Done**.
4. Add the app action **StarPilot BT › Send to StarPilot** and set its **Place** to **Shortcut Input**.

Opening `starpilot://share?text=<URL-encoded shared text>` does the same from inside the app.
