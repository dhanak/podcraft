"""Host HTTP relay through engine exec; runtime keeps network=none."""

import argparse
import contextlib
import http.client
import os
import signal
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

# Bound untrusted responses while streaming large static WASM bundles.
MAX_BODY = 128 * 1024 * 1024
HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class Relay(BaseHTTPRequestHandler):
    engine = ""
    container = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def log_message(self, format, *args):  # noqa: A002
        # Intentional: requests cannot grow a host-side access log forever.
        pass

    def do_GET(self):  # noqa: N802
        self.forward()

    def do_HEAD(self):  # noqa: N802
        self.forward()

    def forward(self):
        if not self.path.startswith("/"):
            self.send_error(400)
            return
        command = [
            self.engine,
            "exec",
            self.container,
            "curl",
            "--noproxy",
            "*",
            "--http1.0",
            "--include",
            "--silent",
            "--max-time",
            "30",
            "--max-filesize",
            str(MAX_BODY),
        ]
        if self.command == "HEAD":
            command.append("--head")
        command += ["--url", "http://127.0.0.1:8080" + self.path]
        sent_headers = False
        with contextlib.ExitStack() as stack:
            reader, writer = socket.socketpair()
            stack.enter_context(reader)
            stack.enter_context(writer)
            reader.settimeout(30)
            process = subprocess.Popen(
                command, stdout=writer.fileno(), stderr=subprocess.DEVNULL
            )
            writer.close()
            try:
                response = stack.enter_context(
                    http.client.HTTPResponse(reader, method=self.command)
                )
                response.begin()
                if response.length is not None and response.length > MAX_BODY:
                    raise ValueError("response too large")
                self.send_response_only(response.status, response.reason)
                for key, value in response.getheaders():
                    if key.lower() not in HOP_HEADERS:
                        self.send_header(key, value)
                self.end_headers()
                sent_headers = True
                total = 0
                while chunk := response.read(64 * 1024):
                    total += len(chunk)
                    if total > MAX_BODY:
                        raise ValueError("response too large")
                    self.wfile.write(chunk)
            except (OSError, http.client.HTTPException, ValueError):
                if not sent_headers:
                    self.send_error(502, "Container relay failed")
                self.close_connection = True
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()


def container_logs(engine, container):
    try:
        subprocess.run(
            [engine, "logs", "--tail", "50", container],
            stdout=sys.stderr,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        print(
            f"relay: could not read container logs: {error}",
            file=sys.stderr,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", choices=("podman", "docker"))
    parser.add_argument("container")
    parser.add_argument("port", type=int)
    parser.add_argument("--detach", action="store_true")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or args.container.startswith("-"):
        parser.error("invalid port or container")
    Relay.engine, Relay.container = args.engine, args.container
    server = HTTPServer(("127.0.0.1", args.port), Relay)

    try:
        subprocess.run(
            [
                args.engine,
                "exec",
                args.container,
                "curl",
                "--noproxy",
                "*",
                "--fail",
                "--silent",
                "--show-error",
                "--retry",
                "3",
                "--retry-connrefused",
                "--retry-delay",
                "1",
                "--max-time",
                "1",
                "--url",
                "http://127.0.0.1:8080/",
            ],
            stdout=subprocess.DEVNULL,
            timeout=10,
            check=True,
        )
    except (OSError, subprocess.SubprocessError) as error:
        print(f"relay: server startup failed: {error}", file=sys.stderr)
        container_logs(args.engine, args.container)
        server.server_close()
        return 1
    print(
        f"Serving http://127.0.0.1:{args.port}/ (offline runtime).",
        flush=True,
    )
    if args.detach:
        if os.fork():
            server.server_close()
            return
        os.setsid()
        with open(os.devnull, "r+b", buffering=0) as sink:
            for fd in (0, 1, 2):
                os.dup2(sink.fileno(), fd)

    def stop(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    watcher = subprocess.Popen(
        [args.engine, "wait", args.container],
        stdout=subprocess.PIPE,
        text=True,
    )
    stopping = threading.Event()
    exit_status = 0

    def watch():
        nonlocal exit_status
        output, _ = watcher.communicate()
        if not stopping.is_set():
            try:
                exit_status = int(output.strip())
                if watcher.returncode or not 0 <= exit_status <= 255:
                    raise ValueError("container wait failed")
            except ValueError:
                exit_status = 1
                print("relay: container wait failed", file=sys.stderr)
            if exit_status:
                print(
                    f"relay: container exited with status {exit_status}",
                    file=sys.stderr,
                )
                container_logs(args.engine, args.container)
        server.shutdown()

    worker = threading.Thread(target=watch, daemon=True)
    worker.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stopping.set()
        server.server_close()
        if watcher.poll() is None:
            watcher.kill()
        worker.join()
        subprocess.run(
            [args.engine, "stop", "--time", "2", args.container],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
        if not args.debug:
            subprocess.run(
                [args.engine, "rm", args.container],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
    return exit_status


if __name__ == "__main__":
    sys.exit(main())
