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
STATEMENTS = os.path.join(HERE, "..", "src-tauri", "statements.json")
TYPES = {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
    ".json": "application/json", ".wasm": "application/wasm", ".png": "image/png", ".svg": "image/svg+xml",
    ".ico": "image/x-icon", ".ttf": "font/ttf", ".pfb": "application/octet-stream",
    ".bcmap": "application/octet-stream", ".icc": "application/octet-stream", ".txt": "text/plain; charset=utf-8",
    ".md": "text/plain; charset=utf-8",
}
BOOK_NAME = re.compile(r"^[0-9a-f]{64}\.(pdf|epub|txt|md|rtf|html)$")


class Backend:
    def __init__(self, dictionary, data, open_files=()):
        self.lock = threading.Lock()
        self.waiting = list(open_files)
        self.taken = []
        self.dictionary = sqlite3.connect(f"file:{dictionary}?mode=ro", uri=True, check_same_thread=False)
        self.dictionary.execute("PRAGMA query_only = ON")
        os.makedirs(os.path.join(data, "Böcker"), exist_ok=True)
        self.data = data
        self.users = {
            "ord": sqlite3.connect(os.path.join(data, "anvandarord.sqlite"), check_same_thread=False, isolation_level=None),
            "bibliotek": sqlite3.connect(os.path.join(data, "bibliotek.sqlite"), check_same_thread=False, isolation_level=None),
        }
        # Samma namngivna frågor och samma start som i appen (src-tauri/statements.json, W12).
        with open(STATEMENTS, encoding="utf-8") as file:
            self.statements = json.load(file)
        for name, database in self.statements["databases"].items():
            connection = self.users[name]
            connection.executescript("\n".join(database["schema"]))
            for table, columns in database.get("columns", {}).items():
                existing = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
                for column, definition in columns:
                    if column not in existing:
                        connection.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")

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
            if command in ("db_read", "db_write"):
                kind = "read" if command == "db_read" else "write"
                if args["name"] not in self.statements[kind]:
                    raise KeyError(f"Okänd fråga: {args['name']}")
                db, sql = self.statements[kind][args["name"]]
                cursor = self.users[db].execute(sql, args.get("params", []))
                return self.rows(cursor) if kind == "read" else cursor.rowcount
            if command == "test_sql":
                # Bara i provservern: testerna läser och skriver i databaserna med egen SQL. Appen har inget
                # sådant kommando (W12).
                return self.rows(self.users[args["db"]].execute(args["sql"], args.get("params", [])))
            if command == "library_store":
                # Som i appen: först en tillfällig fil, som byter namn när den är skriven.
                path = self.book_path(headers.get("x-id", ""), headers.get("x-ext", ""))
                with open(path + ".tmp", "wb") as file:
                    file.write(body)
                os.replace(path + ".tmp", path)
                return None
            if command == "library_read":
                with open(self.book_path(args["id"], args["ext"]), "rb") as file:
                    return file.read()
            if command == "library_size":
                return os.path.getsize(self.book_path(args["id"], args["ext"]))
            if command == "library_read_range":
                with open(self.book_path(args["id"], args["ext"]), "rb") as file:
                    file.seek(int(args["start"]))
                    self.ranges = getattr(self, "ranges", 0) + 1
                    return file.read(max(0, min(int(args["end"]) - int(args["start"]), 64 * 1024 * 1024)))
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
                if name not in ("sync-publishable-key", "sync-refresh-token", "gemini-api-key"):
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
            if command == "pending_take":
                # Som Öppna med i appen: filerna från --open, en gång.
                self.taken, self.waiting = self.waiting, []
                return [{"name": os.path.basename(path)} for path in self.taken]
            if command == "pending_read":
                with open(self.taken[int(args["index"])], "rb") as file:
                    return file.read()
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
    parser.add_argument("--open", nargs="*", default=[], help="böcker som om de öppnats med Öppna med i Utforskaren")
    args = parser.parse_args()
    with open(CONFIG, encoding="utf-8") as file:
        config = json.load(file)
    # Samma policy som i appen, utan Tauris egna adresser för anropen. Bara här får sidan dessutom
    # anropa 127.0.0.1, så att synken kan provas mot låtsasservern (windows/tests/mock_supabase.py).
    csp = config["app"]["security"]["csp"].replace(" ipc: http://ipc.localhost", "")
    csp = csp.replace("https://*.supabase.co", "https://*.supabase.co http://127.0.0.1:*")
    backend = Backend(args.dictionary, args.data, args.open)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(backend, csp))
    print(f"Läsa på http://127.0.0.1:{args.port}/ (pid {os.getpid()}, data i {args.data})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
