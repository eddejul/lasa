"""En liten låtsas-Supabase för simulatortestet av synken (fas 6).

Svarar på samma anrop som appen gör mot ett riktigt Supabase-projekt: inloggning
(/auth/v1/token) och tabellerna (/rest/v1/<tabell>, GET med select, limit och offset, POST med
on_conflict som lägger in eller skriver över). Allt ligger i minnet, och efter varje ändring skrivs
tabellerna till en JSON-fil så att testet kan visa vad appen skickade.

Användning: python3 tools/simtest/mock_supabase.py <port> <frö.json> <utfil.json>
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ANON = "test-anon"
TOKEN = "token-1"
USER = "00000000-0000-4000-8000-000000000001"
TABLES = {
    "positions": ["user_id", "book_id"],
    "highlights": ["id"],
    "bookmarks": ["id"],
    "saved_words": ["user_id", "lemma", "language"],
}

state = {name: [] for name in TABLES}
out_path = None
requests_log = []


def save():
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump({"tables": state, "requests": requests_log}, handle, ensure_ascii=False, indent=1)


def key_of(row, columns):
    return tuple(str(row.get(column, "")).lower() for column in columns)


class Handler(BaseHTTPRequestHandler):

    def log_message(self, *args):
        pass

    def reply(self, code, body=None):
        data = b"" if body is None else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"null")

    def do_POST(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        requests_log.append(f"POST {url.path}?{url.query}")
        if self.headers.get("apikey") != ANON:
            return self.reply(401, {"message": "Invalid API key"})
        if url.path == "/auth/v1/token":
            body = self.body() or {}
            grant = (query.get("grant_type") or [""])[0]
            if grant == "password" and not (body.get("email") and body.get("password")):
                return self.reply(400, {"error_description": "Invalid login credentials"})
            if grant == "refresh_token" and body.get("refresh_token") != "refresh-1":
                return self.reply(400, {"error_description": "Invalid refresh token"})
            return self.reply(200, {"access_token": TOKEN, "refresh_token": "refresh-1", "expires_in": 3600,
                                    "token_type": "bearer", "user": {"id": USER, "email": body.get("email", "")}})
        if not url.path.startswith("/rest/v1/"):
            return self.reply(404, {"message": "Okänd adress"})
        table = url.path[len("/rest/v1/"):]
        if table not in TABLES:
            return self.reply(404, {"message": f"relation {table} does not exist"})
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(401, {"message": "JWT expired"})
        if "resolution=merge-duplicates" not in (self.headers.get("Prefer") or ""):
            return self.reply(409, {"message": "duplicate key value violates unique constraint"})
        columns = (query.get("on_conflict") or [",".join(TABLES[table])])[0].split(",")
        rows = self.body()
        if not isinstance(rows, list) or not rows:
            return self.reply(400, {"message": "Body must be a non-empty array"})
        keys = set(tuple(sorted(row.keys())) for row in rows)
        if len(keys) != 1:
            return self.reply(400, {"message": "All object keys must match"})
        for row in rows:
            if row.get("user_id") not in (None, USER):
                return self.reply(403, {"message": "new row violates row-level security policy"})
            row["user_id"] = USER
            existing = next((old for old in state[table] if key_of(old, columns) == key_of(row, columns)), None)
            if existing is None:
                state[table].append(row)
            else:
                existing.update(row)
        save()
        return self.reply(201)

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        requests_log.append(f"GET {url.path}?{url.query}")
        if self.headers.get("apikey") != ANON or self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(401, {"message": "JWT expired"})
        table = url.path[len("/rest/v1/"):]
        if table not in TABLES:
            return self.reply(404, {"message": f"relation {table} does not exist"})
        limit = int((query.get("limit") or ["1000"])[0])
        offset = int((query.get("offset") or ["0"])[0])
        rows = sorted(state[table], key=lambda row: row.get("updated_at", ""))
        return self.reply(200, rows[offset:offset + limit])


def main():
    global out_path
    port = int(sys.argv[1])
    with open(sys.argv[2], encoding="utf-8") as handle:
        seed = json.load(handle)
    out_path = sys.argv[3]
    for table, rows in seed.items():
        for row in rows:
            row.setdefault("user_id", USER)
        state[table] = rows
    save()
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
