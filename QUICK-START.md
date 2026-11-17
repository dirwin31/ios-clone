# iPhone quick start

Use an iPhone and a comma running a StarPilot build with compatible Galaxy and Bluetooth support.

## Install the app

Open your TestFlight invitation on the iPhone and install the build offered there.

To build it yourself, open `GalaxyBluetooth.xcodeproj` at the root of this repo in Xcode. Choose your signing team, connect your iPhone, select it as the destination and press Run. Follow the phone's trust and Developer Mode prompts if shown.

## Connect and pair

1. Park and leave comma powered on and offroad for setup. It needs internet for the first bridge installation.
2. Join the same Wi-Fi network as comma, or join comma’s hotspot. In the app, select comma and wait for the Wi-Fi connection to be verified.
3. Tap **Pair Bluetooth with comma** in the app’s Advanced connection options. The app opens comma’s pairing window automatically. Allow Bluetooth and Local Network access when asked.
4. Open Galaxy and check that settings load.
5. If you also want phone music, choose **Set up** next to **Phone music** and follow the instructions to finish audio pairing in iPhone Bluetooth settings.

If you choose **Forget** for the phone in comma’s Bluetooth settings, reconnect over Wi-Fi and run the app’s Bluetooth setup again.

## Choose a connection

- **Automatic:** uses the first available connection in your saved order. Tap **Set order** to arrange Wi-Fi, Tunnel and Bluetooth.
- **Bluetooth** lets you access nearby settings without a network on either device.
- **Local Wi-Fi** uses the local network. Both devices must be able to reach each other.

For recordings, replay, cameras, or other features that show a Wi-Fi message, switch to Local Wi-Fi.

## Updates and support

Install app updates through TestFlight. Galaxy’s screens update separately from your comma when you reconnect over Wi-Fi. If a download fails, the app keeps the last saved copy.

If something goes wrong, open **Logs & support** in app Settings. Describe what happened and include your phone model, comma version, and connection mode. Review the report before sending it.
