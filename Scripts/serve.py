#!/usr/bin/env python3

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import sys


class CrossOriginIsolatedHandler(SimpleHTTPRequestHandler):
    def guess_type(self, path: str) -> str:
        if path.endswith("-datapack.bundle.json.gz"):
            return "application/json"
        return super().guess_type(path)

    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        if self.path.split("?", 1)[0].endswith("-datapack.bundle.json.gz"):
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        super().end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    ThreadingHTTPServer(("127.0.0.1", port), CrossOriginIsolatedHandler).serve_forever()
