#!/usr/bin/env python3
"""Small TCP helpers for lab/ebpf/run.sh.

  conn.py serve PORT              accept and hold connections until the peer closes
  conn.py probe HOST PORT N       open N short connections, print ok/failed
  conn.py hold HOST PORT N        open N connections and keep them open until SIGTERM
"""
import asyncio
import signal
import socket
import sys
import time


async def _serve(port):
    async def handle(reader, writer):
        try:
            await reader.read()  # wait for EOF
        finally:
            writer.close()

    servers = []
    for host in ("0.0.0.0", "::"):
        fam = socket.AF_INET6 if ":" in host else socket.AF_INET
        sock = socket.socket(fam, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if fam == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((host, port))
        sock.listen(4096)
        servers.append(await asyncio.start_server(handle, sock=sock, backlog=4096))
    await asyncio.gather(*(s.serve_forever() for s in servers))


def _connect(host, port, timeout=1.0):
    s = socket.create_connection((host, port), timeout=timeout)
    s.settimeout(None)
    return s


def probe(host, port, n):
    ok = 0
    t0 = time.time()
    for _ in range(n):
        try:
            _connect(host, port).close()
            ok += 1
        except OSError:
            pass
    print(f"probe {host}:{port}  ok={ok} failed={n - ok}  ({time.time() - t0:.1f}s)", flush=True)


def hold(host, port, n):
    socks, failed = [], 0
    for _ in range(n):
        try:
            socks.append(_connect(host, port, timeout=0.3))
        except OSError:
            failed += 1
    print(f"hold {host}:{port}  open={len(socks)} failed={failed}", flush=True)

    def bye(*_):
        for s in socks:
            s.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, bye)
    while True:
        signal.pause()


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "serve":
        asyncio.run(_serve(int(sys.argv[2])))
    elif cmd == "probe":
        probe(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    elif cmd == "hold":
        hold(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
