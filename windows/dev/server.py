"""Kör Windows-appens gränssnitt i en vanlig webbläsare, utan Tauri.

Servern visar windows/src och svarar på samma kommandon som Rust-delen (src-tauri/src/main.rs) under
/api/<kommando>, mot en ordboksfil och en egen datamapp. Sidorna får samma Content-Security-Policy
som i appen (läses ur tauri.conf.json), så att provkörningen fångar samma fel.

  python windows/dev/server.py --dictionary <lasa-ordbok.sqlite> [--data <mapp>] [--port 8955]

Lyssnar bara på 127.0.0.1. Länkar som appen skulle öppna i webbläsaren skrivs till opened_urls.txt
i datamappen i stället för att öppnas.
"""

import argparse
import json
import mimetypes
import os
import re
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "src"))
CONFIG = os.path.join(HERE, "..", "src-tauri", "tauri.conf.json")
TYPES = {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
    ".json": "application/json", ".wasm": "application/wasm", ".png": "image/png", ".svg": "image/svg+xml",
    ".ico": "image/x-icon", ".ttf": "font/ttf", ".pfb": "application/octet-stream",
    ".bcmap": "application/octet-stream", ".icc": "application/octet-stream", ".txt": "text/plain; charset=utf-8",
    ".md": "text/plain; charset=utf-8",
}
BOOK_NAME = re.compile(r"^[0-9a-f]{64}\.(pdf|epub|txt|md)$")


class Backend:
    def __init__(self, dictionary, data):
        self.lock = threading.Lock()
        self.dictionary = sqlite3.connect(f"file:{dictionary}?mode=ro", uri=True, check_same_thread=False)
        self.dictionary.execute("PRAGMA query_only = ON")
        os.makedirs(os.path.join(data, "Böcker"), exist_ok=True)
        self.data = data
        self.users = {
            "ord": sqlite3.connect(os.path.join(data, "anvandarord.sqlite"), check_same_thread=False, isolation_level=None),
            "bibliotek": sqlite3.connect(os.path.join(data, "bibliotek.sqlite"), check_same_thread=False, isolation_level=None),
        }

    @staticmethod
    def rows(cursor):
        return [list(row) for row in cursor.fetchall()]

    def book_path(self, book_id, ext):
        name = f"{book_id}.{ext}"
        if not BOOK_NAME.match(name):
            raise ValueError("Ogiltigt namn på bokfilen.")
        return os.path.join(self.data, "Böcker", name)

    def handle(self, command, args, body, headers):
        with self.lock:
            if command == "dict_query":
                sql = args["sql"]
                if not sql.lstrip().lower().startswith(("select", "with")):
                    raise ValueError("Ordboken tar bara emot frågor som läser.")
                return self.rows(self.dictionary.execute(sql, args.get("params", [])))
            if command == "user_query":
                return self.rows(self.users[args["db"]].execute(args["sql"], args.get("params", [])))
            if command == "user_execute":
                return self.users[args["db"]].execute(args["sql"], args.get("params", [])).rowcount
            if command == "user_batch":
                self.users[args["db"]].executescript(args["sql"])
                return None
            if command == "library_store":
                with open(self.book_path(headers.get("x-id", ""), headers.get("x-ext", "")), "wb") as file:
                    file.write(body)
                return None
            if command == "library_read":
                with open(self.book_path(args["id"], args["ext"]), "rb") as file:
                    return file.read()
            if command == "library_delete":
                path = self.book_path(args["id"], args["ext"])
                if os.path.exists(path):
                    os.remove(path)
                return None
            if command in ("secret_get", "secret_set"):
                # Appen sparar hemligheterna i Windows Autentiseringshanteraren. Provservern har en fil i
                # datamappen i stället, bara för provningen.
                path = os.path.join(self.data, "hemligheter-provserver.json")
                secrets = {}
                if os.path.exists(path):
                    with open(path, encoding="utf-8") as file:
                        secrets = json.load(file)
                name = args["name"]
                if name not in ("sync-publishable-key", "sync-refresh-token"):
                    raise ValueError(f"Okänd hemlighet: {name}")
                if command == "secret_get":
                    return secrets.get(name)
                if args.get("value"):
                    secrets[name] = args["value"]
                else:
                    secrets.pop(name, None)
                with open(path, "w", encoding="utf-8") as file:
                    json.dump(secrets, file)
                return None
            if command == "open_url":
                with open(os.path.join(self.data, "opened_urls.txt"), "a", encoding="utf-8") as file:
                    file.write(args["url"] + "\n")
                return None
        raise KeyError(command)


def make_handler(backend, csp):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def send(self, status, body, content_type, extra=None):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = unquote(urlparse(self.path).path)
            if path == "/":
                path = "/index.html"
            full = os.path.normpath(os.path.join(ROOT, path.lstrip("/")))
            if not full.startswith(ROOT) or not os.path.isfile(full):
                self.send(404, b"Finns inte", "text/plain; charset=utf-8")
                return
            ext = os.path.splitext(full)[1].lower()
            content_type = TYPES.get(ext) or mimetypes.guess_type(full)[0] or "application/octet-stream"
            with open(full, "rb") as file:
                body = file.read()
            extra = {"Content-Security-Policy": csp} if ext == ".html" else None
            self.send(200, body, content_type, extra)

        def do_POST(self):
            path = urlparse(self.path).path
            if not path.startswith("/api/"):
                self.send(404, b"Finns inte", "text/plain; charset=utf-8")
                return
            command = path[len("/api/"):]
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            headers = {key.lower(): value for key, value in self.headers.items()}
            try:
                args = json.loads(body) if headers.get("content-type", "").startswith("application/json") else {}
                result = backend.handle(command, args, body, headers)
            except Exception as error:  # noqa: BLE001 (felet skickas tillbaka som text, som Rust-delen gör)
                self.send(500, str(error).encode("utf-8"), "text/plain; charset=utf-8")
                return
            if isinstance(result, (bytes, bytearray)):
                self.send(200, bytes(result), "application/octet-stream")
            else:
                self.send(200, json.dumps(result, ensure_ascii=False).encode("utf-8"), "application/json")

    return Handler


def main():
    parser = argparse.ArgumentParser(description="Läsa för Windows i en vanlig webbläsare.")
    parser.add_argument("--dictionary", required=True)
    parser.add_argument("--data", default=os.path.join(HERE, "data"))
    parser.add_argument("--port", type=int, default=8955)
    args = parser.parse_args()
    with open(CONFIG, encoding="utf-8") as file:
        config = json.load(file)
    # Samma policy som i appen, utan Tauris egna adresser för anropen. Bara här får sidan dessutom
    # anropa 127.0.0.1, så att synken kan provas mot låtsasservern (windows/tests/mock_supabase.py).
    csp = config["app"]["security"]["csp"].replace(" ipc: http://ipc.localhost", "")
    csp = csp.replace("https://*.supabase.co", "https://*.supabase.co http://127.0.0.1:*")
    backend = Backend(args.dictionary, args.data)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(backend, csp))
    print(f"Läsa på http://127.0.0.1:{args.port}/ (pid {os.getpid()}, data i {args.data})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
