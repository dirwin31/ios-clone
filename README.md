# StarPilot Galaxy for iOS

StarPilot Galaxy brings your comma’s Galaxy interface to your iPhone. You can change a display preference while you’re parked, check that it saved, or pick a place in your favorite maps app and send it to your comma before a trip.

The screens come from the StarPilot software running on your comma. On a compatible build, the app downloads those screens over Wi-Fi and saves a copy on your phone. That’s what lets you open Galaxy over Bluetooth the next time you get in the car, even without internet.

## Connect for the first time

With the car parked and comma powered on, join the same Wi-Fi network on both devices or connect your iPhone to comma’s hotspot. Open the app, allow Local Network access, select your comma, and open Galaxy. To use Bluetooth on future visits, complete Bluetooth setup while Wi-Fi is still connected. [iPhone setup guide](QUICK-START.md)

For everyday use, **Automatic** follows your saved connection order. Local Wi-Fi gives you access to features such as recordings and replay. Paired Bluetooth is useful for nearby settings changes. If you set up **Galaxy tunnel**, you can also reach your comma when you’re away and both devices have internet. [Connection and tunnel guide](docs/companion-guide.md)

## Send a destination

Open a place in Apple Maps, Google Maps, or Waze and tap **Share → StarPilot**. Your comma uses its configured navigation provider to plan the route. The share card tells you whether the route started or the destination was saved. If it was saved, open StarPilot when you’re connected to that comma. You can also use **Send to StarPilot** in Siri Shortcuts. [Destination sharing guide](SHARE-DESTINATION.md)

## CarPlay and navigation

CarPlay shows Overview, Memory, CPU, and Toggles. In Toggles, tap **Increase** or **Decrease** to apply one step and see the updated value. Open **Settings → Navigation → Navigation settings** to configure iPhone and CarPlay navigation. On displays with room for four tabs, open Navigation from Overview. CarPlay Live View is available for testing on the testing branch. The dev branch also includes notification mirroring.

For help with a connection, open **Logs & support** in the app. [Connection testing guide](TESTER-GUIDE.md) · [Privacy](docs/privacy.md)
