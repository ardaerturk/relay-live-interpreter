# Relay for iPhone

Use the native app when you want to start listening, put your iPhone in your pocket, and lock it. It uses the same dedicated translator and private account history as the web app. The server address comes from your private HTTPS invite; the app contains no hosting credentials.

## Install on your own iPhone

1. Install the full **Xcode** app on a Mac. Open **Xcode → Settings → Accounts** and add your Apple Account. The free **Personal Team** is sufficient for your own device.
2. Open **Relay.xcodeproj** from this folder. Wait for Xcode to resolve the pinned WebRTC Swift package. Select the **Relay** target → **Signing & Capabilities**. Select your Personal Team and replace the example bundle identifier with your own unique one. Leave automatic signing on.
3. Connect and trust your iPhone, select it as the run destination, and press **Run**. Enable Developer Mode on the phone if prompted (Settings → Privacy & Security). If iOS asks you to trust the developer, follow its prompt. The minimum iOS version is 17. The simulator is useful for development but cannot verify real AirPods routing or locking.
4. Paste the **full private invite link** into the app. Native and Safari require separate, single-use invites linked to the same account. Invite expiry is 24 hours; redeem before it expires. The resulting device access lasts 30 days. With a free Personal Team, the signing profile expires after seven days; run from Xcode again to renew it. No paid membership or App Store release is needed for this route.

## Updating an existing installation

Open the same Xcode project, keep your existing bundle identifier and Personal Team, select your iPhone and press **Run (⌘R)**. You do not need to delete the app or redeem another invite to update a valid installation. In **… → Audio details**, Relay 1.1 shows the actual input and output routes, iPhone volume, the last detected speech, received translated audio, caption update, and the number of reconnect attempts.

## What happens if a conversation goes quiet?

Relay waits for the captions channel and moving microphone counters before it says **Listening**. **Waiting for speech** means no recent speech was detected on the selected mic; this can happen when the AirPods microphone is closer to the listener than the speaker. **Waiting for translation** means Relay detected sound without a translated response. Speech already in the selected output language can legitimately produce no translation.

During a live session, Relay checks microphone frames, upload packets, received audio energy, caption activity and iOS audio-device events. Ordinary silence does not trigger a reconnect. A short network handover has time to recover in place. If the stream stalls, Relay replaces it, keeps the current transcript, and separates the next words with a paragraph break. Speech during the outage cannot be recovered. Use **… → Reconnect audio** to do this yourself at any time while connected.

Retries back off, wait for internet, respect the server’s start limits and end after repeated failures. There is at most one speculative reconnect for unanswered speech until translated audio returns. Stop always cancels pending retries. Taking a phone call or disconnecting headphones ends listening; your text is still available to save. While locked, iOS can suspend the app during a prolonged outage once its active audio and temporary recovery time run out. Unlock and open Relay if it hasn’t resumed.

## Verify on your hardware

- Connect AirPods in Control Center. Start with English as the listening language. Allow the mic, wait for **Listening**, and have someone speak a German sentence you can check.
- Lock the iPhone with its side button. Without unlocking, have them say a **new** sentence after 30 seconds, then another after two minutes. You should hear the translations in the AirPods **while still locked**. Unlock and check the new words in the transcript. A timer, or already-buffered sound, does not prove the mic kept working.
- Switch apps, try cellular, and repeat in German with English input. If the AirPods disconnect, the network fails, an incoming call takes over, or iOS resets audio, Relay ends or reconnects according to the interruption. After a call or headphone removal, tap Start yourself to resume. Try turning airplane mode on for 15 seconds and off again mid-session; speak a new sentence after recovery and check the earlier words are still visible. Force-quitting ends the session.
- Tap **Stop**, then **Save**. Open **History** on a linked browser or iPhone to read or delete the translated text. Check that the mic indicator goes away after stopping. No audio or original-language transcript is saved.

The app uses AVAudioSession playAndRecord / voiceChat with Bluetooth hands-free routing through the native WebRTC audio device. It declares only the audio background mode, does not prevent the phone from locking, and does not play silent keepalive sounds. iOS chooses the audio route; a headset mic close to the wearer may hear people across a table poorly.

[Apple: audio session while locked](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playandrecord) · [Apple: free Personal Team limits](https://developer.apple.com/support/compare-memberships/) · [WebRTC Swift package](https://github.com/stasel/WebRTC)

The checked-in project opens directly in Xcode; XcodeGen is optional and only needed to regenerate it after editing project.yml.
