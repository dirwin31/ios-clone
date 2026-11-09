# Send a place from Google Maps or Apple Maps

StarPilot BT opens `starpilot://share?text=<shared text>`. A one-time Shortcut puts **Send to StarPilot** in the share sheet of Google Maps, Apple Maps, Safari and Messages.

## Set up the Shortcut (once)

1. Open **Shortcuts** and tap **+**.
2. Tap the shortcut's name, choose **Rename** and enter `Send to StarPilot`.
3. Tap the **ⓘ** (Details), turn on **Show in Share Sheet**, and set the accepted types to **URLs** and **Text**. Tap **Done**.
4. Add the action **URL Encode**, encoding **Shortcut Input**.
5. Add the action **Text** and enter `starpilot://share?text=`, then insert the **URL Encoded Text** variable right after `=`.
6. Add the action **Open URLs**, opening the **Text** from step 5.

## Use it

In Google Maps, open a place, tap **Share**, then **Send to StarPilot**.

- With integrated Navigation turned on, the place opens in Navigation with its route preview.
- Otherwise Galaxy's Navigation page opens with the place, the same as Android's share target. A shared search (a name without coordinates) shows Galaxy's search results to pick from.

Google's short links (`maps.app.goo.gl`) are followed on the phone, only to Google hosts over HTTPS, to read the place's coordinates. Nothing else is sent anywhere.
