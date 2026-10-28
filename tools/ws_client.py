#!/usr/bin/env python3
"""Control-channel test client for the Android host (docs/protocol.md).

usage: ws_client.py <token> [listen_seconds]   (adb forward tcp:8765 tcp:8765 first, or pass HOST=...)
With no call activity it checks the handshake and error paths, then prints every message for listen_seconds.
AUTO=answer|reject replies to every incoming `ring` with that command; HANGUP_AFTER=<seconds> then sends `hangup`.
SMS_ACK=1 acknowledges every `sms`; SEND_SMS="<to>|<body>" sends one text right after hello and prints the result.
UDP_PORT=<port> is announced in `answer` so the host streams call audio to that port (on the address it sees us from).
"""
import asyncio, json, os, sys
import websockets

URL = f"ws://{os.environ.get('HOST', '127.0.0.1')}:8765"


EVENTS = {"ring", "ended", "sms", "sms_result"}


async def react(ws, event):
    """Prints a host event and answers it as the AUTO / SMS_ACK / UDP_PORT / HANGUP_AFTER options ask."""
    print("rx", json.dumps(event, separators=(",", ":")), flush=True)
    if event.get("type") == "sms" and os.environ.get("SMS_ACK"):
        await ws.send(json.dumps({"type": "sms_ack", "id": event["id"]}))
        print("tx sms_ack", event["id"], flush=True)
    if event.get("type") == "ring" and os.environ.get("AUTO"):
        reply = {"type": os.environ["AUTO"], "callId": event["callId"]}
        if os.environ.get("UDP_PORT") and reply["type"] == "answer":
            reply["udpPort"] = int(os.environ["UDP_PORT"])
        await ws.send(json.dumps(reply))
        print("tx", os.environ["AUTO"], flush=True)
        if os.environ.get("HANGUP_AFTER"):
            await asyncio.sleep(float(os.environ["HANGUP_AFTER"]))
            await ws.send(json.dumps({"type": "hangup", "callId": event["callId"]}))
            print("tx hangup", flush=True)


async def ask(ws, message):
    """Sends a message and returns its reply, handling host events that arrive in between (e.g. catch-up rings)."""
    await ws.send(message if isinstance(message, str) else json.dumps(message))
    while True:
        reply = json.loads(await asyncio.wait_for(ws.recv(), 5))
        if reply.get("type") not in EVENTS:
            return reply
        await react(ws, reply)


async def main(token, listen):
    ok = True

    def check(name, cond):
        nonlocal ok
        ok &= bool(cond)
        print(("PASS " if cond else "FAIL ") + name)

    async with websockets.connect(URL, open_timeout=90) as ws:
        reply = await ask(ws, {"type": "hello", "version": 1, "token": "WRONG000"})
        check("wrong token -> unauthorized", reply.get("code") == "unauthorized")

    async with websockets.connect(URL, open_timeout=90) as ws:
        reply = await ask(ws, {"type": "answer", "callId": "x"})
        check("message before hello -> expected_hello", reply.get("code") == "expected_hello")

    async with websockets.connect(URL, open_timeout=90) as ws:
        reply = await ask(ws, {"type": "hello", "version": 1, "token": token})
        check("hello -> hello_ack with capabilities", reply.get("type") == "hello_ack" and "calls" in reply.get("capabilities", []))
        print("capabilities:", reply.get("capabilities"))
        reply = await ask(ws, "not json")
        check("garbage -> bad_message, session stays open", reply.get("code") == "bad_message")
        reply = await ask(ws, {"type": "answer", "callId": "no-such-call"})
        check("answer unknown call -> unknown_call", reply.get("code") == "unknown_call")
        if os.environ.get("SEND_SMS"):
            to, body = os.environ["SEND_SMS"].split("|", 1)
            await ws.send(json.dumps({"type": "sms_send", "clientId": "cli-1", "to": to, "body": body}))
            print("tx sms_send", flush=True)
        if listen:
            print(f"listening {listen}s for call events...")
            try:
                async with asyncio.timeout(listen):
                    async for msg in ws:
                        await react(ws, json.loads(msg))
            except TimeoutError:
                pass
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 0)))
