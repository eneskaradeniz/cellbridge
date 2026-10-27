# tools

`spike_server.py` — Mac-side WebSocket host used to test the iOS spike (`ios/spike`).

    python3 -m venv .venv && .venv/bin/pip install websockets
    .venv/bin/python spike_server.py 60     # send {"type":"ring"} every 60 s
