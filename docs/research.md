# Live interpretation: findings and field trial

**Checked November 19, 2026.** The practical target is one listener wearing AirPods in a room with several people, using an iPhone. The primary language pair is German and English. The user chose OpenAI only and specifically required a model trained for audio translation. No general voice assistant, separate transcription model, or fallback TTS runs in this app.

## Decision

Use Azure OpenAI **`gpt-realtime-translate`**, version **2026-05-06**, on an isolated Global Standard deployment provisioned in Sweden Central. This was the dedicated OpenAI audio translator actually listed for the subscription and region. Both German and English work as inputs and outputs; spoken Turkish can be detected, but Turkish is not among the model's 13 documented output languages. The UI only offers German and English listening. A session produces one target language; change direction by stopping and choosing the other language. Speech already in the target language can produce no translated audio. For two simultaneous listeners wanting different outputs, each needs their own session.

This model translates as speech unfolds; there is no end-of-turn silence threshold to tune, prompt, or output voice preset. OpenAI describes **dynamic voice adaptation**: pitch, style and cadence can follow the speaker and change midstream. This is a perceptual effect, not identification. The translation API does not assign stable names or speaker IDs to its output. Mixed or overlapping people on one microphone are particularly difficult; a separate input track per speaker is the stronger design for remote meetings. A phone in a room does not supply those separate tracks.

| Approach researched | Relevance here | Decision |
| --- | --- | --- |
| Dedicated OpenAI Realtime Translate on Foundry | Continuous speech in, translated speech and captions out; dynamic voice. Matches both requested directions without an intermediate text/TTS pipeline. | Implemented and exercised on Azure. |
| General OpenAI Realtime models on Foundry | Conversational agents can be asked to interpret, but they use a different session contract and are not specifically translation models. | Excluded by requirement. |
| Transcribe → translate text → TTS | Additional stages and buffering; selecting distinct voices would require separate speaker tracking. | Excluded. |
| Microsoft Azure Speech Live Interpreter | Purpose-built alternative. Microsoft's language table separates standard Turkish support from LLM-enhanced targets. Personal Voice is gated by separate approval. | Researched only; no inference, deployment, or fallback. |

## What the live measurements mean

The test fed prerecorded macOS system voices into a real browser WebRTC audio track. Azure returned a remote audio track and target-language captions over the data channel. We kept the same mono track and session across two different voices for each target. In the four-phrase test the voices take turns; a separate production test mixes overlapping voices. Neither proves whether a human listener can identify someone. No ambient or user microphone audio was used in these checks.

**Start of input → first non-silent translated audio**: take a browser monotonic timestamp when a trimmed WAV starts, then sample a Web Audio analyser on the returned track roughly every 20 ms (RMS threshold 0.012). Caption timing uses the first non-empty translated text. This includes the real network and the model; it excludes connection setup, real microphone hardware, Bluetooth playback, and the time for an entire meaningful clause to be spoken. It is not a measurement from a person's mouth to an AirPod. Small first-audio numbers also do not prove the correct word arrived on time.

| Input → target / synthetic voice | Input length | Audio, run 1 | Audio, run 2 | First caption, run 1 |
| --- | ---: | ---: | ---: | ---: |
| German → English / Anna | 3.12 s | 2.03 s | 2.26 s | 1.46 s |
| German → English / Eddy | 4.17 s | 3.19 s | 2.62 s | 2.41 s |
| English → German / Samantha | 3.64 s | 2.23 s | 1.91 s | 1.65 s |
| English → German / Reed | 3.42 s | 2.38 s | 2.47 s | 1.62 s |

Eight pre-production utterances across four sessions. The first translated audio arrived before the source sentence finished in all eight. There was still an audible delay. These are four sentences repeated twice, not eight independent situations or a representative p95. Don't compare them as a controlled benchmark against the user's Apple or Google measurements.

**Meaning:** In the first run, “Der Zug nach Berlin fährt um neun Uhr von Gleis vier” came back with “Deep fall in Berlin” at the start, even though nine and platform four survived. The repeat recovered “The train to Berlin” but added “a.m.”, absent from the source. “Ich warte am Bahnhof” became roughly “I’m at the station” in a repeat, losing the waiting intent. The English → German restaurant and meeting examples preserved the numbers and core meaning in both runs.

**Voice distinction:** In the recorded repeat, a simple autocorrelation estimate of median pitch on voiced frames gave roughly **163/117 Hz** for the two German inputs versus **129/120 Hz** in the English output; **180/111 Hz** for the two English inputs versus **130/144 Hz** in the German output. Pitch does not measure speaker identity or timbre and this estimator can make octave errors. The samples are evidence against promising strong separation from a single input.

## Production verification

The same four isolated phrases went through the public Vercel deployment using a single-use test invite and restricted server credentials. German → English first audio took **2.55 s and 3.05 s**; English → German took **2.38 s and 2.98 s**. Captions arrived in **1.55–2.40 s**. Even when the platform, time and meeting place were correct, the English translation of “Danke” started with “No” in this run. This reinforces why first audio and accuracy should be evaluated separately.

A further mono-track trial used the **same two German voices and words** with either a 0.30 s gap or **1.30 s of overlap**. The first speaker says a train to Hamburg leaves at six. The second says to meet on platform three. Both translated captions retained the city, time and platform. The first translated sound came at **3.18 s** with the gap and **3.47 s** with overlap, after the overlapping input had already finished (3.04 s). This one success does not establish robust separation, reliable speaker IDs, or cafe performance.

Across the first twelve individual phrases (four phrases, three runs) the range was **1.91–3.19 s**. For the four production individual phrases alone the median was **2.76 s**. These are descriptive statistics for this test set. A further production run with the history feature enabled returned first translated audio at 2.44, 2.80, 2.12 and 3.07 s for the four phrases, respectively. For each direction a second browser page reopened the saved text and deleted it. The native Swift account client separately verified linked-device access and rejected a read from an unrelated account.

Verified in the in-app browser and in Chrome at desktop and phone-size viewports: initial screen, language choice, guide, invite gate, and no horizontal overflow. Production browser automation also verified invite redemption, both remote audio tracks, live captions, Stop releasing the input and output, and no runtime/console errors. Anonymous requests to start translation returned HTTP 401. Test invites were subsequently revoked. Real iPhone/AirPods behavior remains the next field test.

The native WebRTC implementation was also exercised through the production broker on a Mac using the Mac Catalyst framework slice. An in-memory audio device supplied a prerecorded German train sentence (no live microphone) and measured actual audio energy on the returned track. Both English words about the Berlin train and audible translated output arrived. The native interface and audio configuration type-checked against the Apple SDK. This test does not measure Bluetooth, iPhone hardware or screen locking.

## Transport, headphones and locking

- WebRTC carries the live mono microphone track directly between the browser and Azure. The browser posts an SDP offer to a short Vercel function; the function authenticates the device, obtains a translation-only ephemeral token, exchanges the SDP at Azure, and returns only the answer. The browser receives only the SDP answer; it receives no permanent Azure credentials or ephemeral tokens. Relay never records audio. Translated captions remain in memory unless the invited user explicitly saves them to account history. Azure processes the audio; Global Standard is not a promise of Sweden-only data processing.
- A connected headset can become the input as well as the output. A microphone aimed at the wearer is a poor match for people across a table. Try placing the phone near the group, selecting an available phone mic under **Guide → Find inputs**, and routing output to AirPods in Control Center. Browser/OS routing determines which combinations are available. Relay cannot enforce an AirPods-specific microphone/output split.
- WebKit supports the **Screen Wake Lock API** for Home Screen apps from iOS 18.4. It keeps an eligible visible screen awake. Locking the screen is a different operation; the specification calls for releasing the screen lock on loss of visibility. The service worker is only an offline launch fallback and does not control a microphone. Relay leaves an ongoing WebRTC session alone on a mere visibility change, checks for interrupted capture on return, closes on navigation, and never silently restarts a paid session. Actual screen-off capture, AirPods routing and interruption/resume were not verified on an iPhone. **Use the web version in the foreground for dependable capture.**
- The native iOS companion configures a duplex play-and-record audio session and declares the audio background mode. Start before locking and test on the actual phone; see [the device procedure](../ios/README.md). A paid Apple Developer Program membership is **not** required to install a personal build through Xcode. Apple documents that free Personal Team profiles expire in seven days and require rebuilding/reinstalling. Distribution and real device testing are different issues.

## Cost

Microsoft's Azure OpenAI retail pricing page lists **USD 2.04 per hour** for GPT-Realtime-Translate Global in Sweden Central (about **USD 0.034 per minute**, or **USD 0.34 for ten minutes** at that rate). This is a list-price estimate; the subscription's currency, agreement, credit eligibility, actual meter, and tax can differ. It does not include the small access-table or hosting costs. Check Cost Management rather than inferring actual spend from the length of an MP3 or the amount of speech. Stop sessions when finished. The UI ends ordinary sessions at 20 minutes, and the server allows 20 starts per device per UTC day. A client timer and a start limit are not a hard spend ceiling, especially if a browser is suspended. Global Standard is usage-based; this app does not provision dedicated model throughput.

## Next test on the actual phone

Run the same 10–20 phrases through Relay and the existing apps on the same phone, target, route and network. Test quiet alternating speakers, an interruption mid-sentence, overlapping voices, fast German, numbers and names. Have a bilingual listener mark whether meaning survived. Randomize who speaks; ask a listener looking away to identify A or B from translated audio alone. Record simple counts as well as typical and worst-case delays; include omissions and stalls. Use an external recorder only with participant consent to measure actual source-onset → earbud playback. Separately try Wi-Fi and cellular, a manual lock for 30 seconds and two minutes, AirPods disconnect/reconnect, and a phone-call interruption. Confirm both speech receipt and translated audio, then check the microphone indicator turns off after Stop. A visible timer alone proves neither capture nor translation.

## Primary references

1. [Microsoft Foundry: GPT Realtime Translate overview](https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/gpt-realtime-translate) — dedicated model, streaming, hosting and hourly pricing.
2. [OpenAI: Realtime Translation Guide](https://developers.openai.com/cookbook/examples/voice_solutions/realtime_translation_guide) — language lists, dynamic voice adaptation, mixed-room limitations, same-language behavior, evaluation.
3. [OpenAI: Realtime translation API guide](https://developers.openai.com/api/docs/guides/realtime-translation) — WebRTC tracks, translation endpoints and caption events. We verified the corresponding Azure-hosted translation endpoints live.
4. [Microsoft: GPT Realtime over WebRTC](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-webrtc) and [translation-specific WebSocket examples](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-websockets#translate-audio-in-real-time).
5. [Microsoft Azure OpenAI pricing](https://azure.microsoft.com/en-us/pricing/details/azure-openai/) — Audio Models → GPT-Realtime-Translate Global; the region-specific pricing data in the US page includes Sweden Central.
6. [Microsoft: Speech language support](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support) and [Live Interpreter setup](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-use-live-interpreter).
7. [WebKit: Safari 18.4](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/), [W3C: Screen Wake Lock](https://www.w3.org/TR/screen-wake-lock/) and [W3C: Media Capture and Streams](https://www.w3.org/TR/mediacapture-streams/).
8. [Apple: membership comparison and Personal Team limits](https://developer.apple.com/support/compare-memberships/) and [AVAudioSession playAndRecord](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playandrecord).
