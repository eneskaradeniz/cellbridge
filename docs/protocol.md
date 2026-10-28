# CellBridge protocol (v1)

Android (host) <-> iOS (client, iPhone). Same Wi-Fi hotspot, no internet needed.
Host address: the hotspot gateway (its subnet is not fixed; the iOS app asks the system for the Wi-Fi gateway).

## Control channel — WebSocket (TCP), JSON text frames
Host listens on `ws://<host>:8765`. Every message has `"type"`.

| type | dir | fields |
|---|---|---|
| `hello` | iOS -> host | `version` (int, currently 1), `token` |
| `hello_ack` | host -> iOS | `version`, `capabilities` (`calls`, `sms`, `audio`) |
| `error` | host -> iOS | `code`, `message?` |
| `ring` | host -> iOS | `callId`, `number`, `name?` |
| `answer` / `reject` / `hangup` | iOS -> host | `callId` |
| `ended` | host -> iOS | `callId`, `reason?` |
| `dial` | iOS -> host | `clientId`, `number`, `udpPort?` |
| `dial_result` | host -> iOS | `clientId`, `ok`, `callId?`, `error?` |
| `answered` | host -> iOS | `callId` |
| `sms` | host -> iOS | `id` (string), `from`, `body`, `ts` (ms since epoch) |
| `sms_ack` | iOS -> host | `id` |
| `sms_send` | iOS -> host | `clientId`, `to`, `body` |
| `sms_result` | host -> iOS | `clientId`, `ok`, `error?` |

`audio` is advertised only when the root audio daemon is reachable; without it the host runs in control-only mode
(calls and SMS work, call audio stays on the phone) and the client must not open the audio channel.

`hello` must be the first message. The `token` is the pairing secret shown on the host's screen, entered once on the iPhone;
a wrong token, wrong version or any other first message gets `error` (`unauthorized` / `unsupported_version` / `expected_hello`)
and the host closes the socket. Later errors (`bad_message`, `unknown_call`) leave the session open.
`ended.reason` is `missed` for an incoming call that ended without being answered (the caller gave up), `rejected` when the host
rejected it on the client's request; it is absent for a call that was answered. After `hello_ack` the host re-sends `ring` for every
call that is still ringing, so a reconnecting client catches up; clients dedupe by `callId`.

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

Keep-alive: WebSocket ping every 10 s; client reconnects after 2 s.

## Audio channel — UDP
16 kHz, 16-bit, mono PCM, 20 ms frames (320 samples = 640 bytes) + 4-byte header: `u16 seq`, `u16 reserved` (little endian).
The audio daemon on the host talks UDP directly to the client; the Android app only tells it who the peer is.
Host port: **8767** (fixed, `cellbridge_audiod serve ... [udp_port]`). The client announces its own UDP port in `answer`
(`{"type":"answer","callId":...,"udpPort":N}`) and sends from that port; the host sends downlink frames to it and drops uplink
packets from any other address. Downlink and uplink run for as long as the call is active.
Both ends run a small adaptive jitter buffer (target 60-160 ms, starts at 60 ms, grows by 20 ms after a starvation, shrinks after
5 s without one; a burst of up to target + 10 frames is absorbed without dropping audio, because a phone's Wi-Fi power
saving delivers audio in bursts of 100-150 ms).
Senders must pace frames at one per 20 ms rather than sending a block of them at once. A missing frame is replaced by silence; packets that arrive too late are dropped. Opus may replace PCM later.

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
