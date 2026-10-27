# CellBridge protocol (draft v0)

Android (host, Mi 8 Lite) <-> iOS (client, iPhone). Same Wi-Fi hotspot, no internet needed.
Host address: hotspot gateway (usually `192.168.43.1`); mDNS discovery is optional.

## Control channel — WebSocket (TCP), JSON text frames
Host listens on `ws://<host>:8765`. Every message has `"type"`.

| type | dir | fields |
|---|---|---|
| `hello` | iOS -> host | `version` |
| `hello_ack` | host -> iOS | `version`, `capabilities` (`calls`, `sms`, `audio`) |
| `ring` | host -> iOS | `callId`, `number`, `name?` |
| `answer` / `reject` / `hangup` | iOS -> host | `callId` |
| `ended` | host -> iOS | `callId`, `reason?` |
| `dial` | iOS -> host | `number` |
| `sms` | host -> iOS | `id`, `from`, `body`, `ts` |
| `sms_send` | iOS -> host | `to`, `body` |

`audio` is advertised only when the root audio daemon is reachable; without it the host runs in control-only mode
(calls and SMS work, call audio stays on the phone) and the client must not open the audio channel.

Keep-alive: WebSocket ping every 10 s; client reconnects after 2 s.

## Audio channel — UDP
16 kHz, 16-bit, mono PCM, 20 ms frames (320 samples = 640 bytes) + 4-byte header: `u16 seq`, `u16 reserved`.
Receiver runs a small adaptive jitter buffer (target 40-80 ms). Opus may replace PCM later.
Ports: TBD (host binds one port, client announces its port in the `answer` message).
