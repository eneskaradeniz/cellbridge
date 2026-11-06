# CellBridge protocol (v1)

Android (host) <-> iOS (client, iPhone). Same Wi-Fi hotspot, no internet needed.
Finding the host: the host advertises `_cellbridge._tcp` on port 8765 (Bonjour / mDNS) with the TXT records `v=1`, `id=<random installation id>`
(not secret, not derived from the pairing code) and `ip=<IPv4 addresses of the host's Wi-Fi/hotspot interfaces, comma separated>`. The client browses for it and
takes the `ip` address on its own subnet (resolving the service name's address is the fallback when `ip` is missing: the system's cached answer can be stale
after the host's address changed), so a changed address is found again. When several
hosts announce themselves the one whose `id` the client paired with is chosen. Fallbacks: an address typed by the user, and on the host's own hotspot the
Wi-Fi gateway (its subnet is not fixed; the iOS app asks the system for it).

Pairing: the host shows a QR code on request holding `cellbridge://pair?code=<pairing code>&id=<installation id>&port=8765&host=<address>` (`host` optional).
The client reads it once, keeps the code in its Keychain and the id for choosing among announcements, and sends the code as `token` in `hello`.

## Control channel — WebSocket (TCP), JSON text frames
Host listens on `ws://<host>:8765`. Every message has `"type"`.

| type | dir | fields |
|---|---|---|
| `hello` | iOS -> host | `version` (int, currently 1), `token` |
| `hello_ack` | host -> iOS | `version`, `capabilities` (`calls`, `sms`, `audio`, `calllog`, `smshistory`, `push`, `live`, `hold`, `transfer`, `status`, `conference` (draft)) |
| `call_list` | host -> iOS | `callIds` (every call that is still live) |
| `capabilities` | host -> iOS | `capabilities` (the full list again, sent when it changes) |
| `tone` | host -> iOS | `action` (`start`/`stop`), `kind?` (`generator`/`media`), `id?` (ToneGenerator constant), `name?` (media tone) |
| `error` | host -> iOS | `code`, `message?` |
| `ring` | host -> iOS | `callId`, `number`, `name?` |
| `answer` / `reject` / `hangup` | iOS -> host | `callId` |
| `host_status` | host -> iOS | `battery?` (0-100), `charging`, `signal?` (0-4), `operator?` |
| `ring_ack` | iOS -> host | `callId` |
| `dtmf` | iOS -> host | `callId`, `digit` (one of `0-9 * #`) |
| `transfer_to_host` | iOS -> host | `callId` |
| `transfer_result` | host -> iOS | `callId`, `ok` |
| `transfer_offer` | host -> iOS | `callId`, `number?`, `connectedAt?` (ms since epoch) |
| `transfer_accept` | iOS -> host | `callId`, `udpPort?` |
| `transfer_request` | iOS -> host | `callId` |
| `call_state_request` | iOS -> host | (none) |
| `call_state` | host -> iOS | `calls`: list of `{callId, number?, direction` (`in`/`out`)`, status` (`ringing`/`dialing`/`active`/`holding`)`, connectedAt?, onClient}` |
| `ended` | host -> iOS | `callId`, `reason?` |
| `dial` | iOS -> host | `clientId`, `number`, `udpPort?` |
| `dial_result` | host -> iOS | `clientId`, `ok`, `callId?`, `error?` |
| `answered` | host -> iOS | `callId` |
| `hold` / `unhold` | iOS -> host | `callId` |
| `held` | host -> iOS | `callId`, `held` (bool) |
| `merge` | iOS -> host | `callId` (either of the two calls) |
| `merge_result` | host -> iOS | `callId`, `ok`, `error?` |
| `conference` | host -> iOS | `callId` (the conference), `children` (call ids; empty = dissolved) |
| `sms` | host -> iOS | `id` (string), `from`, `body`, `ts` (ms since epoch) |
| `sms_ack` | iOS -> host | `id` |
| `sms_send` | iOS -> host | `clientId`, `to`, `body` |
| `sms_result` | host -> iOS | `clientId`, `ok`, `error?` |
| `sms_status` | host -> iOS | `clientId`, `status` (`delivered` / `failed`) |
| `call_log_request` | iOS -> host | `after?` (host call id, string), `since?` (ms since epoch) |
| `call_log` | host -> iOS | `entries`: `id`, `number`, `name?`, `kind`, `ts`, `duration` |
| `sms_history_request` | iOS -> host | `since?` (ms since epoch) |
| `sms_history` | host -> iOS | `items`: `id`, `peer`, `body`, `ts`, `dir` |
| `hold` | iOS -> host | `callId` |
| `unhold` | iOS -> host | `callId` |
| `live_start_token` | iOS -> host | `token` (hex) |
| `live_update_token` | iOS -> host | `callId`, `token` (hex) |
| `push_token` | iOS -> host | `token` (hex), `env` (`sandbox`/`production`), `topic`, `key` (base64, 32 bytes), `alert_token?` (hex), `alert_topic?` |

`audio` is advertised only when the root audio daemon is reachable; without it the host runs in control-only mode
(calls and SMS work, call audio stays on the phone) and the client must not open the audio channel.

`hello` must be the first message. The `token` is the pairing secret shown on the host's screen, entered once on the iPhone;
a wrong token, wrong version or any other first message gets `error` (`unauthorized` / `unsupported_version` / `expected_hello`)
and the host closes the socket. Later errors (`bad_message`, `unknown_call`) leave the session open.
`ended.reason` is `missed` for an incoming call that ended without being answered (the caller gave up), `rejected` when the host
rejected it on the client's request; it is absent for a call that was answered. After `hello_ack` the host re-sends `ring` for every
call that is still ringing, so a reconnecting client catches up; clients dedupe by `callId`.

Call list: right after `hello_ack` (before the repeated `ring`s) the host sends `call_list` with the id of every call that is still live, an empty
list when there is none. A `ended` sent while the socket was down is lost for good, so the client ends every call it still shows under a
`callId` that is not in the list (as if `ended` without a reason had arrived). Calls without a `callId` yet (a `dial` still waiting for its
`dial_result`) are left alone.

Capabilities: `hello_ack` lists what the host can do at that moment. The root audio daemon may start a few seconds after the app (boot, a
restart), so while `audio` is missing the host checks again every 5 s and, when the list changed, sends `capabilities`; the client replaces
the list it holds. Nothing is sent when the list is the same.

Tones: the phone itself makes the sounds a call has besides the far end's voice (ringback, busy, call waiting, the beep at the end of a call), so they are
not in the relayed audio. The host forwards what Telecom plays: `tone` `start` with `kind` `generator` and `id` = the Android `ToneGenerator` constant
(`16` dial, `17` busy, `18` congestion, `19` radio ack, `21` error, `22` call waiting, `23` ringback), or with `kind` `media` and `name` = the sound file
Telecom plays (`endcall`, `InCallQualityNotification`, `record`). `stop` ends a looping generator tone; a media tone plays to its end and is not
stopped. A tone the client does not know is ignored. Nothing is sent when Android plays nothing (no coverage), so the client stays silent too.

Ringing: the client answers every `ring` with `ring_ack` (also the repeats after a reconnect) once its own call UI is up. The host then
silences the phone's ringtone and vibration for that call, so only the iPhone rings; without an ack (no client, a dead socket) the
phone keeps ringing and a call is never swallowed. `ring_ack` has no reply. (The reference host quietens the ringer through Do Not Disturb, see
`docs/setup-android.md`; without that access both phones ring.)

Phone status: after `hello_ack` and whenever it changes (checked every 30 s) the host sends `host_status`: battery percentage, whether it
is charging, the cellular signal bars (0-4) and the operator name. A client shows it and warns before the phone's battery runs out.

Tones: `dtmf` plays one keypad tone into the call (menus of banks and call centres). The host plays it for about 150 ms; a client with
several digits sends them one by one, about 200 ms apart. An unknown call gets `error` `unknown_call`, any other digit `bad_message`.

Transfer: an active call can change hands without hanging up. `transfer_to_host` asks the host to stop the audio relay for the call; the call
goes on on the phone itself (its own earpiece, microphone and speaker) and the host answers with one `transfer_result`. The client then
ends its own call UI **without** sending `hangup`, and does not log the call (the phone's call log has it). The other way round, `transfer_offer`
hands a running call to the client (today nothing on the phone triggers it, since the phone has no call screen of its own; the iPhone's take-over button is planned); a connected client puts the active call on its
screen (as an answered call under `callId`, its timer counting from `connectedAt`) and replies with `transfer_accept` carrying its `udpPort`, which starts the audio relay
for that call. A client that cannot take the call simply does not reply. `transfer` is advertised with `audio`.

Seeing and taking the phone's calls: a call can also start on the phone itself (answered or dialed in its stock Phone app), or sit there after
`transfer_to_host`. A client that wants to show those sends `call_state_request` once per connection (like `call_log_request`, so older
clients never get it); the host answers at once with `call_state`, the phone's live calls, and sends a fresh `call_state` whenever a call
starts, changes or ends, or its audio moves to or from a client (`onClient` says the client's relay carries it). `connectedAt` is milliseconds
since epoch and absent until the call connects. The client lists the calls with `onClient` false that it does not know itself, and
`transfer_request` (`callId`) asks the host to take one over: the host answers with the `transfer_offer` above for an `active` call
that is not already on the client, and with `error` `unknown_call` otherwise. A `holding` call can be taken over too: the client then shows it held and offers to resume it. The rest is the `transfer_offer` / `transfer_accept` exchange.
Asking for a call that is `ringing` or `dialing` is an error: a ringing call already rings on the client (`ring`).

Outgoing calls: `dial` is answered by exactly one `dial_result` with the same `clientId`. On `ok:true` the call exists on the host
under `callId` (dialing); `answered` follows when the far end picks up (it is also sent for incoming calls once they are
active, clients may ignore it there) and `ended` when the call is over. `udpPort` works as in `answer`: audio starts when the call
becomes active. `ok:false` carries `error`: `invalid` (not a plain phone number; `*`/`#` codes are refused), `emergency`
(emergency numbers are never dialed through the bridge), `busy` (an outgoing call is already in progress), `failed`
(the platform refused or did not start the call in time).

Hold: `hold` puts a call on hold at the network (the other party hears the hold tone) and `unhold` takes it off again; `hold` is advertised
in `capabilities`. The host asks Telecom, which acts only if the carrier allows it for that call; the result is the call's `status` in `call_state` (`holding`
or `active`, `onClient` unchanged), which the client watches, so a hold from the phone's own screen shows on the client as well. Asking about a
call that is not live is `unknown_call`. A held call stays relayed: the client simply stops sending its microphone while it is held.

Conference (DRAFT, not implemented; `conference` is advertised in `capabilities` only when the carrier allows holding and merging; a client that
does not know it never sees these messages): `hold` / `unhold` put a call on hold on the phone or take it off again. The host answers with
`held` for that call, and sends `held` as well when the user holds a call on the phone itself; a request the platform refuses simply
produces no `held`. A second call while one is active is either an outgoing `dial` (the host holds the active call first, the platform
does it anyway; the `busy` refusal then applies only to a call that is still dialing) or an incoming `ring` (call waiting); `answer` on
the waiting call holds the active one. `merge` joins the held call and the active call into a conference: the host answers
`merge_result` (`ok:false` carries `error`: `unsupported`, `no_pair` when there are not exactly two mergeable calls, `failed`) and, on success, sends `conference` with a new `callId` and
its `children`; the child calls stay known under their ids but do not send `ended` when they merge. Whenever a member leaves, `conference` is sent again
with the remaining `children` (an empty list when it falls apart); a conference ends with `ended` like any call, and `hangup` on it ends
all members. At most 5 members (the carrier limit). Audio stays one stream: the relay carries whichever call is active, or the
conference, and is silent while every call is held; `udpPort` of a second call is ignored while a relay runs. Open: whether the
operator mixes the conference on this CS line (needs a measurement with two real calls) and what the downlink daemon does when the active call changes.

SMS delivery is lossless: the phone's stock Messages app (the default SMS app) stores every incoming message in the system SMS database; the host watches the inbox and sends `sms` for each new row, so whatever the client misses is still in the database. `sms_ack`
acknowledges that message **and every earlier one** (ids only ever increase and are never reused, even after a text is deleted on the host); after `hello_ack` the host re-sends everything newer than the last
acknowledged id, so a client that was offline (or crashed before saving) catches up. Clients persist a message before acking it and
dedupe by `id`. `sms` is advertised in `capabilities` only while the host app may read and send texts (the SMS permissions).
`sms_send` is idempotent: the host remembers the `clientId` of every text it sent (the last few hundred, across restarts) and answers a repeated
`clientId` with the earlier result without sending again, so a client that never saw the answer (the connection dropped) simply sends it again
after reconnecting. `sms_status` reports the operator's delivery report for a sent text (`delivered`, or `failed` when the report says it
never will be); after `hello_ack` the host repeats the `delivered` ones it remembers, clients ignore what they know. Not every operator sends reports.
`sms_send` is answered by exactly one `sms_result` with the same `clientId`; `ok:false` carries a short `error`
(`invalid` for a bad number or empty/oversized body, `failed` when the radio refused). Long texts are sent as multipart messages.
MMS is not supported.

History: everything that happened while the client was away can be fetched, so the iPhone shows what the phone's own logs show.
`calllog` is advertised while the host may read the phone's call log, `smshistory` while the host app may read the phone's texts.
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

Waking the client for a text: a VoIP push may only start a call, so a text uses a second, ordinary (alert) push. The client adds
`alert_token` (the token of its normal remote-notification registration, not the PushKit one) and `alert_topic` (the bundle id,
without `.voip`) to `push_token`; `env` and `key` apply to both. A host that gets `push_token` without them never sends text pushes.
When a text arrives and no client is connected, the host posts at once; when one is connected it waits 10 s and posts only if the
text has not been acknowledged (`sms_ack`) by then (the socket may be dead or the app suspended). The push is `apns-push-type: alert`,
priority 10, `apns-collapse-id` = `sms-<id>`, expiry one day, and its body is
`{"aps": {"alert": {"title-loc-key": "NEW_MESSAGE"}, "mutable-content": 1, "sound": "default"}, "cb": "<sealed>"}`, where `sealed` is the
same box as for calls (same key and context string) around `{"id":...,"from":...,"body":...,"ts":...}`; `body` is cut to 500 characters.
Apple therefore sees neither number nor text. The client's notification service extension opens the box and replaces the generic
"New message" with sender and text; if it cannot, the generic notice stays. The client remembers the ids it has shown this way and
does not notify them again when the same text is replayed after a reconnect (`sms` / `sms_history` stay lossless; only the notice is skipped).

Live Activity (lock screen and Dynamic Island) for a call that runs on the phone: iOS lets only a push start a Live Activity while the app
is in the background, so the host does it. `live` is advertised with `push`. The client sends `live_start_token` (the token ActivityKit gives
for starting an activity by push) after every `hello_ack`, and `live_update_token` (`callId` and the push token of that call's activity) as
soon as ActivityKit has made one; the host keeps the start token with the push target and the update tokens in memory only. The host shows
every call that is `active` or `holding` is not relayed to a client (`onClient` false) and is therefore on the phone: it posts `start` when
the call enters that set, `update` when its status changes and `end` when it leaves (hung up, or taken over by a client). APNs headers:
`apns-push-type: liveactivity`, `apns-topic: <bundle id>.push-type.liveactivity` (the bundle id is `alert_topic`), priority 10.
`update` and `end` need the call's update token: until it arrives the host holds them back and sends them when it does (an activity that
never reports a token ends by itself at its `stale-date`, 4 hours after the start). The body is
`{"aps": {"timestamp": s, "event": "start"|"update"|"end", "content-state": {...}, "stale-date": s, "dismissal-date": s (end only),
"attributes-type": "CallActivityAttributes", "attributes": {"callId": ...}, "alert": {"title": "CellBridge", "body": "On the phone", "loc-key": "On the phone"}}}` (the last three only for `start`; ActivityKit drops a start whose alert lacks a title or a body). `content-state` is
`{"status": "active"|"holding", "connectedAtMs": ms, "outgoing": bool, "sealed": "<sealed>"}` where `sealed` is the usual box around
`{"number": ...}` (absent for a private caller); only the status and the connect time, which the timer needs, travel in clear. iOS gives the process that draws a
Live Activity no Keychain, so the widget cannot open the box: the app can (the system wakes it for a push-started activity), and writes the
caller's contact name, or the number, into the state's `name`; a later push replaces the state without `name`, so the app adds it again
whenever it runs and sees an update. Until then the card says only "On the phone". The activity's "Take over" button opens `cellbridge://takeover?call=<callId>`;
the app answers with `transfer_request` once it is connected.

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
| `0x90` TONE line | daemon -> app | one Telecom log line about a call tone (UTF-8, at most 400 bytes); sent to the authenticated client at any time, also while no relay runs |
| `0x03` HOTSPOT | app -> daemon | `u8 on` (1 or 0): switch the phone's Wi-Fi hotspot on or off (see below). Answered with OK, or ERR once it is known to have failed; an on request takes about 6 s |
| `0x04` WIFI | app -> daemon | - ; answered with `0x82` |
| `0x82` WIFI info | daemon -> app | UTF-8 text, one name per line: the Wi-Fi network the phone is connected to (an empty first line if none), then every network saved on the phone |
| `0x05` SAVE_SENT | app -> daemon | `i64 date` (ms since epoch, LE), UTF-8 `address`, one `\n`, UTF-8 `body`: files a text the iPhone sent in the system SMS database's sent box, so the stock Messages app shows it in the thread (only the default SMS app may write the database; the daemon is root). Answered with OK or ERR. The address must be a plain phone number |
| `0x80` OK | daemon -> app | ack of AUTH / START / STOP / HOTSPOT / SAVE_SENT |
| `0x81` ERR | daemon -> app | UTF-8 reason; the request had no effect |

**Hotspot.** The app uses the daemon to bring the hotspot up when the phone leaves its home Wi-Fi and down again when it returns (an app cannot
do it itself). The home Wi-Fi is any network saved on the phone; the app asks with WIFI after every Wi-Fi change and decides. The daemon takes
the hotspot's name, password and band from the Wi-Fi service's own saved hotspot settings (WPA2 only), never from the app, and starts it with
`cmd wifi start-softap`; the Tethering service then serves addresses and internet exactly as for a hotspot switched on by hand. OFF stops
whatever hotspot is running.

The daemon follows the `Telecom` log (`logcat`) and forwards the lines of `InCallTonePlayer` and `RingbackPlayer` as `0x90` frames: the app turns them into `tone` messages (control channel). STOP, a closed socket, or SIGTERM switch every mixer route off. The app must hold a `PARTIAL_WAKE_LOCK` while started,
otherwise the CPU suspends and the DSP feed stalls (see spike-a doc).
