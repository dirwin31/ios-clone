# Send a place from Google Maps or Apple Maps

StarPilot BT adds a **Send to StarPilot** action to Shortcuts. A one-time Shortcut puts it in the share sheet of Google Maps, Apple Maps, Safari and Messages. Sharing a place sets comma's destination and starts the route without opening the app.

## Set up the Shortcut (once)

1. Open **Shortcuts** and tap **+**.
2. Tap the shortcut's name, choose **Rename** and enter `Send to StarPilot`.
3. Tap the **ⓘ** (Details), turn on **Show in Share Sheet**, and set the accepted types to **URLs** and **Text**. Tap **Done**.
4. Add the app action **StarPilot BT › Send to StarPilot** and set its **Place** to **Shortcut Input**.

## Use it

In Google Maps, open a place, tap **Share**, then **Send to StarPilot**. Shortcuts confirms "Route to … started on comma."

The place reaches comma over the app's current connection, then the saved home network address, then the Galaxy tunnel when it is signed in. Navigation is turned on if it was off. It needs a Mapbox token in Galaxy's Navigation settings.

When comma can't be reached, or the shared text has no map location (a name to search for), Shortcuts offers to open StarPilot BT. Galaxy's Navigation page then opens with the place or its search results, the same as Android's share target.

Opening `starpilot://share?text=<URL-encoded shared text>` does the same from inside the app.

Google's short links (`maps.app.goo.gl`) are followed on the phone, only to Google hosts over HTTPS, to read the place's coordinates. Nothing else is sent anywhere.
