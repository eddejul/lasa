"""En liten låtsas-Gemini för simulatortestet av Förklara stycket (A1) och nyckelguiden (U7).

Svarar på samma anrop som appen gör mot Google: generateContent (POST /v1beta/models/<modell>:generateContent)
och provet av nyckeln (GET /v1beta/models/<modell>). Svaret beror på nyckeln i x-goog-api-key:

  mock-ok            ett svar enligt schemat (kärna, begrepp, exempel, kontrollfråga och svar)
  mock-bad           400, API key not valid (som Google)
  mock-quota-day     429 med quotaId GenerateRequestsPerDayPerProjectPerModel-FreeTier
  mock-quota-minute  429 med quotaId GenerateRequestsPerMinutePerProjectPerModel-FreeTier och retryDelay 30s

En modell som heter finns-inte ger 404. Varje anrop skrivs till en JSON-fil (nyckeln maskad, frågans längd och
början), så att testet kan visa att bara stycket skickades. Ingen riktig nyckel används någonsin.

Användning: python3 tools/simtest/mock_gemini.py <port> <utfil.json>
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

out_path = None
requests_log = []


def save():
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump({"requests": requests_log}, handle, ensure_ascii=False, indent=1)


def google_error(code, status, message, details=None):
    error = {"code": code, "message": message, "status": status}
    if details:
        error["details"] = details
    return {"error": error}


def quota_error(per_day):
    quota_id = ("GenerateRequestsPerDayPerProjectPerModel-FreeTier" if per_day
                else "GenerateRequestsPerMinutePerProjectPerModel-FreeTier")
    return google_error(429, "RESOURCE_EXHAUSTED", (
        "You exceeded your current quota, please check your plan and billing details.\n"
        "* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, "
        "limit: 20, model: gemini-3.5-flash-lite\nPlease retry in 29.6s."), [
        {"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [{
            "quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests",
            "quotaId": quota_id, "quotaValue": "20"}]},
        {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "29.6s"},
    ])


ANSWER = {
    "core": "Stycket säger att man förstår en idé bättre när man ser den i ett sammanhang. Det viktiga är "
            "hur delarna hänger ihop, inte varje detalj för sig.",
    "concepts": [
        {"term": "sammanhang", "definition": "Det som står runt en text och ger den mening."},
        {"term": "helhet", "definition": "Alla delar tillsammans, sedda som en enhet."},
    ],
    "example": "En enda pusselbit säger lite, men när den ligger på rätt plats i pusslet ser du vad den visar.",
    "question": "Varför räcker det inte att förstå varje del för sig?",
    "answer": "För att meningen uppstår i hur delarna hänger ihop.",
}


class Handler(BaseHTTPRequestHandler):

    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        path = unquote(urlparse(self.path).path)
        key = self.headers.get("x-goog-api-key", "")
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        prompt = ""
        schema = False
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
            prompt = "".join(part.get("text", "") for content in body.get("contents", [])
                             for part in content.get("parts", []))
            schema = "responseJsonSchema" in body.get("generationConfig", {})
        except (ValueError, AttributeError):
            body = {}
        entry = {"method": method, "path": path, "key": key if key.startswith("mock-") else "(annan)",
                 "prompt_length": len(prompt), "prompt_start": prompt[:300], "schema": schema}
        requests_log.append(entry)
        save()

        if not path.startswith("/v1beta/models/"):
            return self.reply(404, google_error(404, "NOT_FOUND", "Okänd adress"))
        model = path[len("/v1beta/models/"):].split(":")[0]
        if key == "mock-bad" or not key.startswith("mock-"):
            return self.reply(400, google_error(400, "INVALID_ARGUMENT",
                                                "API key not valid. Please pass a valid API key."))
        if model == "finns-inte":
            return self.reply(404, google_error(404, "NOT_FOUND", f"models/{model} is not found"))
        if method == "GET":
            return self.reply(200, {"name": f"models/{model}", "displayName": model})
        if key == "mock-quota-day":
            return self.reply(429, quota_error(True))
        if key == "mock-quota-minute":
            return self.reply(429, quota_error(False))
        if not path.endswith(":generateContent"):
            return self.reply(404, google_error(404, "NOT_FOUND", "Okänd metod"))
        text = json.dumps(ANSWER, ensure_ascii=False)
        return self.reply(200, {"candidates": [{"content": {"role": "model", "parts": [{"text": text}]},
                                                "finishReason": "STOP"}]})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


def main():
    global out_path
    port = int(sys.argv[1])
    out_path = sys.argv[2]
    save()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
