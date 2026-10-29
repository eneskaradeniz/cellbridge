# CellBridge protocol (v1)

Android (host) <-> iOS (client, iPhone). Same Wi-Fi hotspot, no internet needed.
Host address: the hotspot gateway (its subnet is not fixed; the iOS app asks the system for the Wi-Fi gateway).

## Control channel — WebSocket (TCP), JSON text frames
Host listens on `ws://<host>:8765`. Every message has `"type"`.

| type | dir | fields |
|---|---|---|
| `hello` | iOS -> host | `version` (int, currently 1), `token` |
| `hello_ack` | host -> iOS | `version`, `capabilities` (`calls`, `sms`, `audio`, `calllog`, `smshistory`, `push`, `transfer`) |
| `error` | host -> iOS | `code`, `message?` |
| `ring` | host -> iOS | `callId`, `number`, `name?` |
| `answer` / `reject` / `hangup` | iOS -> host | `callId` |
| `ring_ack` | iOS -> host | `callId` |
| `transfer_to_host` | iOS -> host | `callId` |
| `transfer_result` | host -> iOS | `callId`, `ok` |
| `transfer_offer` | host -> iOS | `callId`, `number?`, `connectedAt?` (ms since epoch) |
| `transfer_accept` | iOS -> host | `callId`, `udpPort?` |
| `ended` | host -> iOS | `callId`, `reason?` |
| `dial` | iOS -> host | `clientId`, `number`, `udpPort?` |
| `dial_result` | host -> iOS | `clientId`, `ok`, `callId?`, `error?` |
| `answered` | host -> iOS | `callId` |
| `sms` | host -> iOS | `id` (string), `from`, `body`, `ts` (ms since epoch) |
| `sms_ack` | iOS -> host | `id` |
| `sms_send` | iOS -> host | `clientId`, `to`, `body` |
| `sms_result` | host -> iOS | `clientId`, `ok`, `error?` |
| `call_log_request` | iOS -> host | `after?` (host call id, string), `since?` (ms since epoch) |
| `call_log` | host -> iOS | `entries`: `id`, `number`, `name?`, `kind`, `ts`, `duration` |
| `sms_history_request` | iOS -> host | `since?` (ms since epoch) |
| `sms_history` | host -> iOS | `items`: `id`, `peer`, `body`, `ts`, `dir` |
| `push_token` | iOS -> host | `token` (hex), `env` (`sandbox`/`production`), `topic`, `key` (base64, 32 bytes) |

`audio` is advertised only when the root audio daemon is reachable; without it the host runs in control-only mode
(calls and SMS work, call audio stays on the phone) and the client must not open the audio channel.

`hello` must be the first message. The `token` is the pairing secret shown on the host's screen, entered once on the iPhone;
a wrong token, wrong version or any other first message gets `error` (`unauthorized` / `unsupported_version` / `expected_hello`)
and the host closes the socket. Later errors (`bad_message`, `unknown_call`) leave the session open.
`ended.reason` is `missed` for an incoming call that ended without being answered (the caller gave up), `rejected` when the host
rejected it on the client's request; it is absent for a call that was answered. After `hello_ack` the host re-sends `ring` for every
call that is still ringing, so a reconnecting client catches up; clients dedupe by `callId`.

Ringing: the client answers every `ring` with `ring_ack` (also the repeats after a reconnect) once its own call UI is up. The host then
silences the phone's ringtone and vibration for that call, so only the iPhone rings; without an ack (no client, a dead socket) the
phone keeps ringing and a call is never swallowed. `ring_ack` has no reply.

Transfer: an active call can change hands without hanging up. `transfer_to_host` asks the host to stop the audio relay for the call; the call
goes on on the phone itself (its own earpiece, microphone and speaker) and the host answers with one `transfer_result`. The client then
ends its own call UI **without** sending `hangup`, and does not log the call (the phone's call log has it). The other way round, when
the user presses "transfer to iPhone" on the phone the host sends `transfer_offer`; a connected client puts the active call on its
screen (as an answered call under `callId`, its timer counting from `connectedAt`) and replies with `transfer_accept` carrying its `udpPort`, which starts the audio relay
for that call. A client that cannot take the call simply does not reply. `transfer` is advertised with `audio`.

Outgoing calls: `dial` is answered by exactly one `dial_result` with the same `clientId`. On `ok:true` the call exists on the host
under `callId` (dialing); `answered` follows when the far end picks up (it is also sent for incoming calls once they are
active, clients may ignore it there) and `ended` when the call is over. `udpPort` works as in `answer`: audio starts when the call
becomes active. `ok:false` carries `error`: `invalid` (not a plain phone number; `*`/`#` codes are refused), `emergency`
(emergency numbers are never dialed through the bridge), `busy` (an outgoing call is already in progress), `failed`
(the platform refused or did not start the call in time).

SMS delivery is lossless: the host stores every incoming message in the system SMS database first, then sends `sms`. `sms_ack`
acknowledges that message **and every earlier one** (ids only ever increase and are never reused, even after a text is deleted on the host); after `hello_ack` the host re-sends everything newer than the last
acknowledged id, so a client that was offline (or crashed before saving) catches up. Clients persist a message before acking it and
dedupe by `id`. `sms` is advertised in `capabilities` only while the host app is the default SMS app.
`sms_send` is answered by exactly one `sms_result` with the same `clientId`; `ok:false` carries a short `error`
(`invalid` for a bad number or empty/oversized body, `failed` when the radio refused). Long texts are sent as multipart messages.
MMS is not supported.

History: everything that happened while the client was away can be fetched, so the iPhone shows what the phone's own logs show.
`calllog` is advertised while the host may read the phone's call log, `smshistory` while the host app is the default SMS app.
`call_log_request` is answered by exactly one `call_log`: entries with a host call id greater than `after` and a time not before `since`
(both optional), the newest 300 at most, oldest first. `kind` is `incoming` (answered), `outgoing`, `missed` or `rejected`; `duration` is
in seconds (0 for anything that was not connected). Ids only increase; a client remembers the highest one it has seen and asks for
newer ones after every `hello_ack`. A client that already created a record for the same call from the live events (same number,
same direction, within 90 s) adopts the host id instead of adding a second record.
`sms_history_request` is answered by one `sms_history`: texts from `since` on (default 90 days), the newest 500 at most, oldest
first; `dir` is `in` or `out`. An incoming item has the same `id` the live `sms` message carries, so a text seen both ways is
stored once; an outgoing item has the id `out-<row>`, and a client matches it to texts it sent itself by number, body and time (within
2 minutes). History texts count as read and are never acknowledged. Clients ask once per installation.

Waking a closed app: iOS only starts an app that was swiped away for a VoIP push (PushKit, via Apple's APNs), so the host sends one
when a call starts ringing. `push` is advertised while the host holds an APNs key. After `hello_ack` the client sends `push_token`
with its PushKit token, whether the build is a development one (`sandbox`) or not (`production`), the APNs `topic`
(bundle id + `.voip`) and `key`: 32 random bytes the client keeps in its Keychain, so nobody but the two phones can read what
the push carries. The host stores the latest `push_token`. When an incoming call rings and no client is connected, it posts to
APNs at once; when a client is connected it waits 3 s and posts only if the call is still ringing (the connection may be dead).
The push body is `{"cb": "<sealed>"}` where `sealed` is base64(`nonce` (12 bytes) + AES-256-GCM ciphertext + tag) of
`{"callId":...,"number":...,"name":...}` under `key`, with the string `cellbridge-push-v1` as additional data. The client must
report a call to CallKit for every push it receives (iOS terminates apps that do not), using a call UUID derived from `callId` so a
push for a call it already knows is harmless; it then connects, and ends the call again if the host does not list it as ringing.

Keep-alive: WebSocket ping every 10 s; client reconnects after 2 s.

## Audio channel — UDP
16 kHz, 16-bit, mono PCM, 20 ms frames (320 samples = 640 bytes) + 4-byte header: `u16 seq`, `u8 flags`, `u8 reserved` (little endian).
`flags` bit 0 = the packet carries the previous frame too: payload is frame `seq` followed by frame `seq - 1` (1280 bytes), so a
single lost packet is repaired by the next one. Receivers accept both sizes (one frame or two) and treat the second frame as a
redundant copy: it is used only if frame `seq - 1` has not arrived. Both ends send redundancy.
The audio daemon on the host talks UDP directly to the client; the Android app only tells it who the peer is.
Host port: **8767** (fixed, `cellbridge_audiod serve ... [udp_port]`). The client announces its own UDP port in `answer`
(`{"type":"answer","callId":...,"udpPort":N}`) and sends from that port; the host sends downlink frames to it and drops uplink
packets from any other address. Downlink and uplink run for as long as the call is active.
Both ends run a small adaptive jitter buffer (target 60-280 ms, starts at 60 ms, grows by 40 ms after a starvation, shrinks by 20 ms
after 5 s without one; a burst of up to target + 10 frames is absorbed without dropping audio, because a phone's Wi-Fi power
saving delivers audio in bursts of 100-250 ms).
Senders must pace frames at one per 20 ms rather than sending a block of them at once. A frame that is still missing at playout is
concealed by repeating the last played frame, fading out over three frames and then silence; packets that arrive too late are
dropped. The Android host holds a low-latency Wi-Fi lock while a call's audio runs. Opus may replace PCM later.

## Audio daemon (on the Android host only, not seen by iOS)
Root daemon `cellbridge_audiod serve <profile> <token>` <-> Android app, TCP `127.0.0.1:8766`, one client at a time.
Frame: `u8 type`, `u16 len` (little endian), `len` bytes payload. Audio payloads are exactly one period
(profile `period_frames`, 16-bit mono -> 640 bytes at 320 frames). The first frame must be `AUTH`; anything else closes the socket.

| type | dir | payload |
|---|---|---|
| `0x00` AUTH | app -> daemon | token (bytes) |
| `0x01` START | app -> daemon | `u8 flags`: bit0 = capture DL, bit1 = inject UL; optional `u8[4] peer ipv4`, `u16 peer port` (LE): audio then flows over UDP (see above) instead of `0x10`/`0x11` frames |
| `0x02` STOP | app -> daemon | - (the daemon logs stream statistics to stderr) |
| `0x10` DL frame | daemon -> app | PCM period (only while started with DL) |
| `0x11` UL frame | app -> daemon | PCM period (only while started with UL) |
| `0x80` OK | daemon -> app | ack of AUTH / START / STOP |
| `0x81` ERR | daemon -> app | UTF-8 reason; the request had no effect |

STOP, a closed socket, or SIGTERM switch every mixer route off. The app must hold a `PARTIAL_WAKE_LOCK` while started,
otherwise the CPU suspends and the DSP feed stalls (see spike-a doc).
