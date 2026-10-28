#!/usr/bin/env python3
"""Control-channel test client for the Android host (docs/protocol.md).

usage: ws_client.py <token> [listen_seconds]   (adb forward tcp:8765 tcp:8765 first, or pass HOST=...)
With no call activity it checks the handshake and error paths, then prints every message for listen_seconds.
AUTO=answer|reject replies to every incoming `ring` with that command; HANGUP_AFTER=<seconds> then sends `hangup`.
"""
import asyncio, json, os, sys
import websockets

URL = f"ws://{os.environ.get('HOST', '127.0.0.1')}:8765"


async def ask(ws, message):
    await ws.send(message if isinstance(message, str) else json.dumps(message))
    return json.loads(await asyncio.wait_for(ws.recv(), 5))


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
        reply = await ask(ws, "not json")
        check("garbage -> bad_message, session stays open", reply.get("code") == "bad_message")
        reply = await ask(ws, {"type": "answer", "callId": "no-such-call"})
        check("answer unknown call -> unknown_call", reply.get("code") == "unknown_call")
        if listen:
            print(f"listening {listen}s for call events...")
            try:
                async with asyncio.timeout(listen):
                    async for msg in ws:
                        print("rx", msg, flush=True)
                        event = json.loads(msg)
                        if event.get("type") == "ring" and os.environ.get("AUTO"):
                            await ws.send(json.dumps({"type": os.environ["AUTO"], "callId": event["callId"]}))
                            print("tx", os.environ["AUTO"], flush=True)
                            if os.environ.get("HANGUP_AFTER"):
                                await asyncio.sleep(float(os.environ["HANGUP_AFTER"]))
                                await ws.send(json.dumps({"type": "hangup", "callId": event["callId"]}))
                                print("tx hangup", flush=True)
            except TimeoutError:
                pass
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 0)))
