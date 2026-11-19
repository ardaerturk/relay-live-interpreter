# Relay · Live interpreter

Choose **English** or **German**, tap **Start listening**, and hear the translation through your headphones. Relay uses only Azure OpenAI’s **gpt-realtime-translate**, a dedicated streaming speech-to-speech translator. The source code is public; using a hosted instance requires a private device invite.

- **iPhone app:** Start a session while the phone is unlocked, wait for **Listening**, then lock it. The app uses a real native duplex audio session and the iOS audio background mode. See [install on your iPhone and check the lock-screen audio](ios/README.md).
- **Web app:** Open the hosted site in Safari (optionally Share → Add to Home Screen). Unlock the device in the browser or Home Screen app you intend to use. Keep it visible for dependable capture: Safari may interrupt a locked phone’s microphone.
- **Transcript:** The translated words appear live. After Stop, tap **Save** to keep them in your private **History**. Linked devices can open or delete that text. Unsaved words are held in memory. Relay does not record audio, transcribe the original language, label speakers, or save anything automatically.

Choose the language you want to **hear**. To change direction, stop, change language, and restart. Speech already in the target language may pass without translated audio. For group conversations, put the active microphone near the speakers. The model adapts its translated voice, but does not assign each person a distinct, persistent voice. In a four-phrase production test, first translated audio arrived about 2.4–3.1 seconds after speech began. [Research, sources and measured limits](docs/research.md).

## Self-host

Requires Node 22.12+ (or 24), an Azure OpenAI resource with the dedicated **gpt-realtime-translate** Global Standard deployment named exactly that, and an Azure StorageV2 account with Table service. No secret belongs in the client, a VITE variable, or this repository.

1. Run `npm ci`. Copy `.env.example` to `.env.local` and supply the Azure OpenAI resource endpoint, its API key, and the operator's storage connection string. Use a private file: `chmod 600 .env.local`.
2. Run `node --env-file=.env.local scripts/history-setup.mjs` to create the history table and a private encryption key. Back up the key securely: losing or changing it makes existing saved words unreadable.
3. Run `npm run dev`. The default web address is `http://localhost:4173`. Issue a single-use invite, saving its link **outside the checkout**:

   ```sh
   APP_ORIGIN=http://localhost:4173 npm run invite -- issue "Test browser" /private/path/browser-invite.txt
   ```

4. For production, link the project to Vercel with its CLI. Initialize the device table by issuing an invite, then run these commands against the linked project. They send production-only secrets via standard input. The hosted service receives limited table grants rather than the operator's storage account key.

   ```sh
   node --env-file=.env.local scripts/hosting-env.mjs YOUR_VERCEL_SCOPE
   node --env-file=.env.local scripts/history-setup.mjs YOUR_VERCEL_SCOPE
   npm test && npm run build
   npx vercel deploy --prod
   ```

   Use the canonical Vercel hostname on devices, or set production `APP_ORIGIN` to your custom HTTPS origin. Do not copy the local origin to Vercel. Renew both table grants before their printed expiry: run `hosting-env.mjs YOUR_VERCEL_SCOPE --rotate` and the same history setup command, then redeploy.

## Invite devices to one account

There is no public signup or shared password. Each invite is valid for 24 hours; after redemption the device can connect for 30 days. The operator gets a nonsecret device ID for linking or revocation. Keep the actual link private. Send **separate invites** for native and web; reusing the same link will fail.

```sh
APP_ORIGIN=https://YOUR-PRODUCTION-HOST npm run invite -- issue "Browser" /private/path/web-invite.txt
APP_ORIGIN=https://YOUR-PRODUCTION-HOST npm run invite -- issue "iPhone" /private/path/phone-invite.txt EXISTING_DEVICE_ID
npm run invite -- revoke DEVICE_ID
```

With no existing device ID, an invitation creates an independent account. With an existing ID, the new device shares its history, including after access renewal. Revocation prevents future API access but cannot close an already-negotiated call.

## Privacy, architecture and checks

The three Vercel functions authenticate invites, negotiate WebRTC, and store explicitly saved translated text. After signaling, microphone and translated audio stream directly between the client and Azure. Tell participants before starting. Relay does not receive live audio at its web server. Azure processes the conversation under the operator’s subscription. No analytics, media recording, or audio upload endpoint is included.

Saved transcript text is compressed and encrypted on the server with AES-256-GCM, bound to its owning account and session metadata. This is **not end-to-end encryption**: the running server can decrypt an authorized read. Date, language and duration are stored alongside the ciphertext. The browser stores access in an HttpOnly, Secure, host-only cookie; the native app uses the iOS Keychain. All private HTTP responses are non-cacheable. Ordinary clients end sessions after 20 minutes; the broker allows 20 starts per device per UTC day. Neither limit is a hard billing cap.

`npm test` tests invite races, isolation, encrypted storage and the exact translation API contract with no credentials. `npm run check:browser` checks the rendered invite gate and both viewport sizes using installed Chrome. For an optional **billable** end-to-end run, set `TEST_ORIGIN`, `TEST_INVITE_FILE` (fresh test account), and `FIXTURES` pointing at synthetic WAVs named `anna`, `eddy` (German), `samantha`, `reed` (English). It checks returned speech, captions, saving, reading in a new page, deleting, and microphone release. Normal clients have no recording code. GitHub CI builds the web and the unsigned iPhone target, then launches the app in a simulator and exercises the device invite gate. No hosted service credentials or Apple signing identity are needed.
