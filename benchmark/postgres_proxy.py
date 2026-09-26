"""Loopback PostgreSQL frame counter with optional ReadyForQuery delay.

Fixture clients disable TLS/GSS and use a disposable local PostgreSQL server.
Only message types/counts are logged, never SQL or parameter payloads.
"""
import collections
import json
import socket
import struct
import sys
import threading
import time

listen_port, upstream_port = map(int, sys.argv[1:3])
delay = float(sys.argv[3]) / 1000
output_lock = threading.Lock()


def exact(sock, n):
    result = bytearray()
    while len(result) < n:
        part = sock.recv(n - len(result))
        if not part:
            raise EOFError
        result.extend(part)
    return bytes(result)


def frame(sock):
    header = exact(sock, 5)
    size = struct.unpack("!I", header[1:])[0]
    if not 4 <= size <= 1 << 28:
        raise ValueError("invalid fixture frame size")
    return header[:1].decode("ascii"), header + exact(sock, size - 4)


def session(client):
    server = socket.create_connection(("127.0.0.1", upstream_port))
    lock = threading.Lock()
    state = {"counts": None, "closing": False}
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    server.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def incoming():
        try:
            while True:
                kind, data = frame(server)
                if kind == "Z" and delay:
                    time.sleep(delay)
                report = None
                with lock:
                    if state["counts"] is not None:
                        state["counts"]["server_" + kind] += 1
                        if kind == "Z" and state["closing"]:
                            report = dict(state["counts"])
                            state["counts"] = None
                            state["closing"] = False
                if report is not None:
                    with output_lock:
                        print(json.dumps({"delay_ms": delay * 1000, **report}), flush=True)
                client.sendall(data)
        except (EOFError, OSError):
            pass
        finally:
            client.close()
            server.close()

    try:
        header = exact(client, 4)
        size = struct.unpack("!I", header)[0]
        server.sendall(header + exact(client, size - 4))
        reader = threading.Thread(target=incoming, daemon=True)
        reader.start()
        while True:
            kind, data = frame(client)
            with lock:
                if kind == "Q" and data[5:] == b"BEGIN\x00":
                    state["counts"] = collections.Counter()
                if state["counts"] is not None:
                    state["counts"]["client_" + kind] += 1
                    if kind == "Q" and data[5:] in (b"COMMIT\x00", b"ROLLBACK\x00"):
                        state["closing"] = True
            server.sendall(data)
    except (EOFError, OSError):
        pass
    finally:
        client.close()
        server.close()


listener = socket.create_server(("127.0.0.1", listen_port))
print(json.dumps({"listen_port": listen_port, "upstream_port": upstream_port,
                  "ready_delay_ms": delay * 1000}), flush=True)
while True:
    client, _ = listener.accept()
    threading.Thread(target=session, args=(client,), daemon=True).start()
