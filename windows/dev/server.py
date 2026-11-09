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
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
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


# Gör sökbar (P1), som ocr_* i main.rs: tools/ocr/sokbar_pdf.py körs med Python och Tesseract, filerna ligger i
# datamappen under OCR och tas bort direkt.
OCR_SCRIPT = os.path.normpath(os.path.join(HERE, "..", "..", "tools", "ocr", "sokbar_pdf.py"))
OCR_ENV = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")


class OcrJob:
    def __init__(self, folder):
        self.lock = threading.Lock()
        self.folder = folder
        self.output = os.path.join(folder, "ut.pdf")
        self.cancel = os.path.join(folder, "avbryt")
        self.state, self.done, self.total, self.message, self.log = "running", 0, 0, "", []
        self.process = None

    def follow(self):
        finished, verdict = False, None
        for raw in self.process.stdout:
            line = raw.decode("utf-8", "replace").strip()
            word, _, rest = line.partition(" ")
            rest = rest.strip()
            with self.lock:
                if word == "START":
                    self.total = int(rest or 0)
                elif word == "SIDA":
                    numbers = rest.split()
                    if len(numbers) >= 2:
                        self.done, self.total = int(numbers[0]), int(numbers[1])
                elif word == "KLAR":
                    finished = True
                elif word == "SAKNAS":
                    verdict = ("missing", rest)
                elif word == "HAR_TEXT":
                    verdict = ("hasText", rest)
                elif word == "AVBRUTEN":
                    verdict = ("cancelled", "")
                elif word == "FEL":
                    verdict = ("error", rest)
        code = self.process.wait()
        time.sleep(0.2)
        with self.lock:
            if finished and code == 0 and os.path.isfile(self.output):
                self.state, self.message = "done", ""
            elif verdict:
                self.state, self.message = verdict
            elif os.path.exists(self.cancel):
                self.state, self.message = "cancelled", ""
            else:
                self.state, self.message = "error", " ".join(self.log[-3:]) or f"Skriptet slutade med kod {code}."
            shutil.rmtree(os.path.join(self.folder, "tmp"), ignore_errors=True)
            if self.state != "done":
                shutil.rmtree(self.folder, ignore_errors=True)

    def read_errors(self):
        for raw in self.process.stderr:
            with self.lock:
                self.log = (self.log + [raw.decode("utf-8", "replace").rstrip()])[-30:]


def ocr_tool_args(args):
    extra = []
    for name in ("tesseract", "tessdata"):
        value = (args.get(name) or "").strip()
        if value:
            extra += [f"--{name}", value]
    return extra


class Backend:
    def __init__(self, dictionary, data, open_files=()):
        self.lock = threading.Lock()
        self.waiting = list(open_files)
        self.taken = []
        self.dictionary = sqlite3.connect(f"file:{dictionary}?mode=ro", uri=True, check_same_thread=False)
        self.dictionary.execute("PRAGMA query_only = ON")
        os.makedirs(os.path.join(data, "Böcker"), exist_ok=True)
        self.data = data
        self.ocr_jobs, self.ocr_next = {}, 0
        shutil.rmtree(os.path.join(data, "OCR"), ignore_errors=True)
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
            self.run_moves(connection, database)

    def run_moves(self, connection, database):
        """Engångsflyttarna (moves, G3), som run_moves i main.rs: kopia av databasfilen först, sedan stegen i en
        transaktion. Går flytten inte fungerar appen ändå."""
        for move in database.get("moves", []):
            if not connection.execute(move["pending"]).fetchone()[0]:
                continue
            seconds = int(time.time())
            copy, extra = os.path.join(self.data, f"{move['backup']} {seconds}.sqlite"), 2
            while os.path.exists(copy):
                copy, extra = os.path.join(self.data, f"{move['backup']} {seconds} {extra}.sqlite"), extra + 1
            try:
                connection.execute("VACUUM INTO ?", (copy,))
                connection.execute("BEGIN IMMEDIATE")
                try:
                    for step in move["steps"]:
                        connection.execute(step)
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
            except sqlite3.Error as error:
                print(f"Flytten kunde inte göras: {error}", file=sys.stderr)

    @staticmethod
    def rows(cursor):
        return [list(row) for row in cursor.fetchall()]

    def book_path(self, book_id, ext):
        name = f"{book_id}.{ext}"
        if not BOOK_NAME.match(name):
            raise ValueError("Ogiltigt namn på bokfilen.")
        return os.path.join(self.data, "Böcker", name)

    def ocr(self, command, args):
        """Gör sökbar, samma kommandon och lägen som i main.rs."""
        python = (args.get("python") or "").strip() or "python"
        if command == "ocr_check":
            try:
                r = subprocess.run([python, "-X", "utf8", OCR_SCRIPT, "--kontroll", *ocr_tool_args(args)],
                                   capture_output=True, timeout=60, env=OCR_ENV)
            except OSError as error:
                return {"ok": False, "saknas": ["python"], "fel": str(error)}
            text = r.stdout.decode("utf-8", "replace")
            for line in reversed(text.splitlines()):
                if line.strip().startswith("{"):
                    try:
                        return json.loads(line)
                    except ValueError:
                        break
            details = (text.strip() + " " + r.stderr.decode("utf-8", "replace").strip()).strip()[:400]
            return {"ok": False, "saknas": ["python"], "fel": details}
        if command == "ocr_start":
            source = self.book_path(args["id"], "pdf")
            if not os.path.isfile(source):
                raise ValueError("Bokfilen finns inte.")
            if any(job.state == "running" for job in self.ocr_jobs.values()):
                raise ValueError("En bok görs redan sökbar. Vänta tills den är klar, eller avbryt den.")
            self.ocr_next += 1
            name = f"{int(time.time())}-{self.ocr_next}"
            folder = os.path.join(self.data, "OCR", name)
            os.makedirs(os.path.join(folder, "tmp"), exist_ok=True)
            job = OcrJob(folder)
            arguments = [python, "-X", "utf8", OCR_SCRIPT, source, job.output, "--tmp", os.path.join(folder, "tmp"),
                         "--avbryt-fil", job.cancel, "--arbetare", "2"]
            if args.get("replace"):
                arguments.append("--ersatt-text")
            try:
                job.process = subprocess.Popen(arguments + ocr_tool_args(args), stdin=subprocess.DEVNULL,
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=OCR_ENV)
            except OSError as error:
                shutil.rmtree(folder, ignore_errors=True)
                raise ValueError(f"Python kunde inte startas ({error}).") from error
            self.ocr_jobs[name] = job
            threading.Thread(target=job.read_errors, daemon=True).start()
            threading.Thread(target=job.follow, daemon=True).start()
            return name
        job = self.ocr_jobs.get(args.get("job"))
        if command == "ocr_discard":
            if job:
                del self.ocr_jobs[args["job"]]
                if job.state == "running":
                    open(job.cancel, "w").close()
                else:
                    shutil.rmtree(job.folder, ignore_errors=True)
            return None
        if job is None:
            raise KeyError("Jobbet finns inte längre.")
        if command == "ocr_status":
            with job.lock:
                return {"state": job.state, "done": job.done, "total": job.total, "message": job.message}
        if command == "ocr_cancel":
            try:
                open(job.cancel, "w").close()
            except OSError:
                pass
            timer = threading.Timer(20, lambda: job.process.poll() is None and job.process.kill())
            timer.daemon = True
            timer.start()
            return None
        if command == "ocr_take":
            if job.state != "done":
                raise ValueError("Filen är inte klar.")
            with open(job.output, "rb") as file:
                data = file.read()
            shutil.rmtree(job.folder, ignore_errors=True)
            del self.ocr_jobs[args["job"]]
            return data
        raise KeyError(command)

    # Synken (F1), som sync_* i main.rs: bara undermappen "Sensus synk" i den valda mappen och filnamn som slutar
    # på .json. LASA_SYNC_SUGGEST (sökvägar med ; emellan) står för iCloud Drive i sync_suggest.
    SYNC_FOLDER = "Sensus synk"

    @staticmethod
    def sync_dir(folder):
        folder = (folder or "").strip()
        if not folder:
            raise ValueError("Ingen synkmapp är vald.")
        if not os.path.isdir(folder):
            raise ValueError(f"Mappen {folder} finns inte. Kontrollera sökvägen och att iCloud för Windows är igång.")
        return os.path.join(folder, Backend.SYNC_FOLDER)

    @staticmethod
    def sync_name(name):
        bad = (not name or len(name) > 200 or name.startswith(".") or not name.lower().endswith(".json")
               or any(c in name for c in "/\\:"))
        if bad:
            raise ValueError(f"Ogiltigt namn på en synkfil: {name}")

    @staticmethod
    def write_atomic(path, data):
        with open(path + ".tmp", "wb") as file:
            file.write(data)
        os.replace(path + ".tmp", path)

    def sync(self, command, args):
        if command == "sync_suggest":
            return [part for part in os.environ.get("LASA_SYNC_SUGGEST", "").split(";") if part]
        folder = self.sync_dir(args.get("folder"))
        if command == "sync_check":
            os.makedirs(folder, exist_ok=True)
            probe = os.path.join(folder, f".sensus-prov-{int(time.time())}.txt")
            text = "Sensus provar att skriva här. Filen tas bort direkt.".encode("utf-8")
            self.write_atomic(probe, text)
            with open(probe, "rb") as file:
                back = file.read()
            os.remove(probe)
            if back != text:
                raise ValueError("Filen som skrevs gick inte att läsa tillbaka likadan.")
            return None
        if command == "sync_list":
            if not os.path.isdir(folder):
                return []
            result = []
            for name in sorted(os.listdir(folder)):
                try:
                    self.sync_name(name)
                except ValueError:
                    continue
                result.append({"name": name, "size": os.path.getsize(os.path.join(folder, name))})
            return result
        name = args.get("name", "")
        self.sync_name(name)
        path = os.path.join(folder, name)
        if command == "sync_read":
            with open(path, "rb") as file:
                data = file.read()
            try:
                return data.decode("utf-8")
            except UnicodeDecodeError:
                raise ValueError(f"{name} är inte text i UTF-8")
        if command == "sync_write":
            os.makedirs(folder, exist_ok=True)
            data = args.get("text", "").encode("utf-8")
            self.write_atomic(path, data)
            with open(path, "rb") as file:
                if file.read() != data:
                    raise ValueError("Synkfilen som sparades gick inte att läsa tillbaka likadan.")
            return None
        if command == "sync_set_aside":
            os.replace(path, os.path.join(folder, f"{name[:-5]}.trasig-{int(time.time())}"))
            return None
        raise KeyError(command)

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
            if command.startswith("ocr_"):
                return self.ocr(command, args)
            if command.startswith("sync_"):
                return self.sync(command, args)
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
    # Samma policy som i appen, utan Tauris egna adresser för anropen.
    csp = config["app"]["security"]["csp"].replace(" ipc: http://ipc.localhost", "")
    backend = Backend(args.dictionary, args.data, args.open)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(backend, csp))
    print(f"Läsa på http://127.0.0.1:{args.port}/ (pid {os.getpid()}, data i {args.data})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
