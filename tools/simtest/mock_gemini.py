"""En liten låtsas-Gemini för simulatortestet av Förklara stycket (A1) och nyckelguiden (U7).

Svarar på samma anrop som appen gör mot Google: generateContent (POST /v1beta/models/<modell>:generateContent)
och provet av nyckeln (GET /v1beta/models/<modell>). Svaret beror på nyckeln i x-goog-api-key:

  mock-ok            ett svar enligt schemat (kärna, begrepp, exempel, kontrollfråga och svar), eller för
                     Förklara kapitlet (A2) punkter där en pekar på en markering som inte finns (M9)
  mock-bad           400, API key not valid (som Google)
  mock-quota-day     429 med quotaId GenerateRequestsPerDayPerProjectPerModel-FreeTier
  mock-quota-minute  429 med quotaId GenerateRequestsPerMinutePerProjectPerModel-FreeTier och retryDelay 30s

AI-frågorna (K6b): en fråga av typen fragor-1 (börjar med "Du gör frågor som hjälper en läsare") får frågor
vars plats och källa tas ur texten mellan <text> och </text> i frågan, plus en fråga vars plats inte står i
texten och en som upprepar sex ord ur texten (båda ska slängas av appens kontroll). Jämför (jamfor-1, "Du
bedömer en läsares svar") får ett omdöme med punkter.

En modell som heter finns-inte ger 404. Varje anrop skrivs till en JSON-fil (nyckeln maskad, frågans längd och
början), så att testet kan visa att bara stycket skickades. Ingen riktig nyckel används någonsin.

Användning: python3 tools/simtest/mock_gemini.py <port> <utfil.json>
"""

import json
import re
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

# A2 Förklara kapitlet: punkter som pekar på studentens markeringar (M1, M2 ...). M9 finns inte i listan och
# ska inte visas i appen.
CHAPTER_ANSWER = {
    "correct": [
        {"text": "Du tar med att talaren har flera bevismedel.", "mark": "M1"},
        {"text": "Du förklarar att talet måste passa publiken och situationen.", "mark": "[M2]"},
    ],
    "missing": [
        {"text": "Kairos, det rätta ögonblicket att säga något, kom inte med.", "mark": "M3"},
        {"text": "Den här punkten pekar på en markering som inte finns.", "mark": "M9"},
    ],
    "wrong": [],
}


def sentences(text):
    """Meningarna i texten med var de slutar, ordagrant (för plats och källa)."""
    result = []
    start = 0
    for match in re.finditer(r"[.!?](?=\s|$)", text):
        sentence = text[start:match.end()].strip()
        if len(sentence.split()) >= 8:
            result.append((sentence, match.end()))
        start = match.end()
    return result


def count_after(prompt):
    match = re.search(r"^a\) (\d+) fråg", prompt, re.M)
    return int(match.group(1)) if match else 2


def questions_answer(prompt):
    """K6b: frågor ur texten i frågan. Platsen är de sex sista orden i en mening, källan de åtta första."""
    text = prompt.split("<text>\n", 1)[-1].rsplit("\n</text>", 1)[0]
    found = sentences(text)
    wanted = count_after(prompt)
    fragor = []
    if found:
        # Den första frågan i texten står tidigt (andra meningen), så att pricken syns på kapitlets första sida.
        picks = sorted({min(1, len(found) - 1)} | {len(found) * (k + 1) // (wanted + 1) for k in range(1, wanted)})
        types = ["varfor", "egna_ord", "skillnad", "vems_rost", "belagg", "huvudpoang", "tillampa", "falla"]
        for number, index in enumerate(picks):
            sentence, _ = found[index]
            words = sentence.rstrip(".!?").split()
            fragor.append({"typ": types[number % len(types)], "nar": "efter",
                           "fraga": f"Vad vill författaren få fram i avsnittet som slutar här, fråga {number + 1}?",
                           "svar": ["Avsnittets huvudtanke med egna ord.", "Varför den spelar roll."],
                           "oppen": False, "plats": " ".join(words[-6:]), "kalla": " ".join(words[:8])})
        first, _ = found[0]
        fragor.insert(0, {"typ": "huvudpoang", "nar": "fore",
                          "fraga": "Vad är det viktigaste du ska hålla utkik efter när du läser kapitlet?",
                          "svar": ["Kapitlets huvudtanke."], "oppen": False, "plats": "",
                          "kalla": " ".join(first.split()[:8])})
        # Slängs: platsen står inte i texten.
        fragor.append({"typ": "huvudpoang", "nar": "efter", "fraga": "En fråga vars plats inte finns i texten?",
                       "svar": ["Inget."], "oppen": False, "plats": "den här platsen står inte i texten alls",
                       "kalla": " ".join(first.split()[:8])})
        # Slängs: frågan upprepar sex ord i rad ur texten.
        fragor.append({"typ": "egna_ord", "nar": "efter", "fraga": "Förklara: " + " ".join(first.split()[:7]) + "?",
                       "svar": ["Något."], "oppen": False, "plats": " ".join(first.rstrip(".").split()[-6:]),
                       "kalla": " ".join(first.split()[:8])})
    if 'Inga frågor med "nar": "slut"' not in prompt:
        fragor.append({"typ": "sammanfatta", "nar": "slut",
                       "fraga": "Sammanfatta kapitlet med egna ord i två eller tre meningar.",
                       "svar": ["Kapitlets huvudtanke.", "Hur resonemanget byggs upp."], "oppen": False, "plats": "",
                       "kalla": ""})
        fragor.append({"typ": "verkligheten", "nar": "slut",
                       "fraga": "Var i ditt eget liv eller din omvärld syns det kapitlet beskriver?",
                       "svar": ["Kapitlets idé kan prövas mot vardagen."], "oppen": True, "plats": "", "kalla": ""})
        if "Det här är bokens sista kapitel" in prompt:
            fragor.append({"typ": "syntes", "nar": "slut",
                           "fraga": "Hur hänger bokens viktigaste idéer ihop, sett från slutet?",
                           "svar": ["Bokens röda tråd."], "oppen": True, "plats": "", "kalla": ""})
    words = re.findall(r"[^\W\d_]{7,}", text)
    return {"sammanfattning": "Kapitlet för ett resonemang i flera steg om det texten handlar om.",
            "begrepp": list(dict.fromkeys(words))[:5], "fragor": fragor}


COMPARE_ANSWER = {
    "med": ["Du fick med huvudtanken."],
    "saknas": ["Varför den spelar roll saknas."],
    "fel": [],
    "omdome": "delvis",
    "kommentar": "En bra början, men förklara också varför det spelar roll.",
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
        if prompt.startswith("Du gör frågor som hjälper en läsare"):
            answer = questions_answer(prompt)
        elif prompt.startswith("Du bedömer en läsares svar"):
            answer = COMPARE_ANSWER
        else:
            answer = CHAPTER_ANSWER if "Studentens förklaring" in prompt else ANSWER
        text = json.dumps(answer, ensure_ascii=False)
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
