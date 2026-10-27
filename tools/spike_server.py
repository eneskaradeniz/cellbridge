"""Spike B host: accepts the iPhone, logs connect/disconnect, sends a 'ring' every N seconds.
usage: spike_server.py [ring_interval_seconds]"""
import asyncio, sys, time
import websockets

INTERVAL = int(sys.argv[1]) if len(sys.argv) > 1 else 600
clients = set()

def ts():
    return time.strftime("%H:%M:%S")

async def handler(ws):
    clients.add(ws)
    print(ts(), "client connected", ws.remote_address, flush=True)
    try:
        async for msg in ws:
            print(ts(), "rx", msg, flush=True)
    finally:
        clients.discard(ws)
        print(ts(), "client gone", flush=True)

async def ringer():
    while True:
        await asyncio.sleep(INTERVAL)
        for ws in list(clients):
            await ws.send('{"type":"ring"}')
            print(ts(), "tx ring", flush=True)
        if not clients:
            print(ts(), "ring skipped: no client", flush=True)

async def main():
    async with websockets.serve(handler, "0.0.0.0", 8765, ping_interval=None):
        await ringer()

asyncio.run(main())
