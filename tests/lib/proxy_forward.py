#!/usr/bin/env python3
"""Forward a TCP port so test containers can use a proxy that only listens on localhost.

Only needed when the machine running the tests reaches the internet through a
proxy on 127.0.0.1 (some CI and cloud sandboxes do). run-docker-test.sh starts
it automatically in that case; stopping it is how the offline test cuts the
container off from the internet.

Usage: proxy_forward.py LISTEN_HOST LISTEN_PORT TARGET_HOST TARGET_PORT
"""

import socket
import sys
import threading


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


def main():
    listen_host, listen_port, target_host, target_port = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((listen_host, listen_port))
    server.listen(128)
    while True:
        client, _ = server.accept()
        try:
            upstream = socket.create_connection((target_host, target_port))
        except OSError:
            client.close()
            continue
        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


if __name__ == "__main__":
    main()
