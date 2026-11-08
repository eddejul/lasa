"""Wiktionary via kaikki.org (O10): ursprung, uttal och fler översättningar till ordboken.

Källan är de svenska orden i engelska Wiktionary, utdragna av Wiktextract (Tatu Ylonen) och utlagda som
JSON Lines på kaikki.org, cirka 360 MB. Filen strömmas och filtreras direkt i bygget och sparas aldrig hel:
bara grundform, ordklass, första meningen av ursprunget, första uttalet och de första förklaringarna sparas
i en liten fil bland källorna (wiktionary-sv-filtrerad.json), så att nästa bygge slipper strömma igen.

Bygget i molnet vet inte vilka böcker Edvin har, så ordboken tar bara med ord som redan finns i den:
svenska grundformer ur SALDO får ursprung och uttal, och engelska förklaringar som är grundformer i
Open English WordNet blir fler svenska översättningar av de engelska orden.

Licens: CC BY-SA 4.0 (Wiktionary) och samma för den bearbetade versionen. Ursprunget är skrivet på engelska
i Wiktionary. De vanligaste orden och språknamnen översätts till svenska här, resten står kvar.
"""

import json
import os
import re
import time
import urllib.request

KAIKKI_SV_URL = "https://kaikki.org/dictionary/Swedish/kaikki.org-dictionary-Swedish.jsonl"
FILTERED_NAME = "wiktionary-sv-filtrerad.json"

# Ursprunget kortas till en mening och högst så här många tecken.
MAX_ETYMOLOGY = 180
# Högst så här många översättningar ur Wiktionary per engelskt ord och ordklass.
MAX_TRANSLATIONS = 6

# Wiktionarys ordklasser till SALDO:s och Open English WordNets.
SV_POS = {"noun": "nn", "verb": "vb", "adj": "av", "adv": "ab", "prep": "pp", "pron": "pn", "conj": "kn",
          "intj": "in", "num": "nl", "article": "al"}
EN_POS = {"noun": "n", "verb": "v", "adj": "a", "adv": "r"}

# Språknamn i genitiv, så att "from Latin" blir "från latinets".
LANGUAGES = {
    "Ancient Greek": "forngrekiskans", "Koine Greek": "koinegrekiskans", "Byzantine Greek": "bysantinsk grekiskas",
    "Greek": "grekiskans", "Medieval Latin": "medeltidslatinets", "Late Latin": "senlatinets",
    "New Latin": "nylatinets", "Vulgar Latin": "vulgärlatinets", "Latin": "latinets",
    "Old Norse": "fornnordiskans", "Old Swedish": "fornsvenskans", "Proto-Norse": "urnordiskans",
    "Old East Norse": "östnordiskans", "Proto-Germanic": "urgermanskans", "Proto-Indo-European": "urindoeuropeiskans",
    "Middle Low German": "medellågtyskans", "Low German": "lågtyskans", "Old High German": "fornhögtyskans",
    "Middle High German": "medelhögtyskans", "German": "tyskans", "Old French": "fornfranskans",
    "Middle French": "mellanfranskans", "French": "franskans", "Old English": "fornengelskans",
    "Middle English": "medelengelskans", "English": "engelskans", "Italian": "italienskans",
    "Spanish": "spanskans", "Portuguese": "portugisiskans", "Dutch": "nederländskans",
    "Middle Dutch": "medelnederländskans", "Danish": "danskans", "Norwegian": "norskans", "Finnish": "finskans",
    "Russian": "ryskans", "Arabic": "arabiskans", "Persian": "persiskans", "Hebrew": "hebreiskans",
    "Sanskrit": "sanskrits", "Turkish": "turkiskans", "Japanese": "japanskans", "Chinese": "kinesiskans",
    "Icelandic": "isländskans", "Polish": "polskans", "Czech": "tjeckiskans", "Hungarian": "ungerskans",
    "Sami": "samiskans", "Yiddish": "jiddischs", "Swedish": "svenskans", "Old Saxon": "fornsaxiskans",
    "Proto-Slavic": "urslaviskans", "Old Church Slavonic": "fornkyrkoslaviskans", "Gothic": "gotiskans",
}
_LANGUAGE_PATTERN = "|".join(re.escape(name) for name in sorted(LANGUAGES, key=len, reverse=True))

# Vanliga uttryck i början av ursprunget. Ordningen spelar roll (längst först).
PHRASES = [
    (r"\b(?:Learned|Semi-learned|Unadapted|Orthographic) borrowing from\b", "lån från"),
    (r"\bBorrowed from\b", "lån från"),
    (r"\bborrowed from\b", "lånat från"),
    (r"\bInherited from\b", "från"),
    (r"\bDerived from\b", "bildat av"),
    (r"\bCompound of\b", "sammansättning av"),
    (r"\bCalque of\b", "översättningslån av"),
    (r"\bClipping of\b", "kortform av"),
    (r"\bShort for\b", "kortform av"),
    (r"\bEquivalent to\b", "motsvarar"),
    (r"\bequivalent to\b", "motsvarar"),
    (r"\bitself\b", "i sin tur"),
    (r"\bthe verb\b", "verbet"),
    (r"\bthe noun\b", "substantivet"),
    (r"\bthe adjective\b", "adjektivet"),
    (r"\bUltimately from\b", "ytterst från"),
    (r"\bultimately from\b", "ytterst från"),
    (r"\bFrom\b", "från"),
    (r"\bfrom\b", "från"),
    (r"\bvia\b", "via"),
    (r"\bUnknown\b", "okänt"),
    (r"\bUncertain\b", "osäkert"),
    (r"\bcognate with\b", "besläktat med"),
    (r"\bCognate with\b", "besläktat med"),
    (r"\bcompare\b", "jämför"),
    (r"\band\b", "och"),
]


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def swedish_etymology(text):
    """Första meningen av ursprunget, med språknamn och vanliga uttryck på svenska."""
    text = re.sub(r"\s+", " ", text or "").strip()
    if not text:
        return ""
    # Första meningen: punkt följd av mellanslag och stor bokstav (inte punkten i "c. 1600" eller "s.k.").
    match = re.search(r"\.\s+(?=[A-ZÅÄÖ])", text)
    if match and match.start() >= 8:
        text = text[:match.start() + 1]
    if len(text) > MAX_ETYMOLOGY:
        cut = text.rfind(", ", 0, MAX_ETYMOLOGY)
        text = (text[:cut] if cut > 40 else text[:MAX_ETYMOLOGY].rsplit(" ", 1)[0]).rstrip(",;: ") + " …"
    for pattern, replacement in PHRASES:
        text = re.sub(pattern, replacement, text)
    text = re.sub(_LANGUAGE_PATTERN, lambda m: LANGUAGES[m.group(0)], text)
    # Old Czech blir forntjeckiskans: "Old" före ett språknamn som redan översatts.
    text = re.sub(r"\bOld ([a-zåäö]+skans)\b", r"forn\1", text)
    return text[:1].upper() + text[1:]


def _entry(item):
    """De fält som ordboken behöver ur en rad, eller None."""
    word = item.get("word") or ""
    if not word or " " in word or len(word) > 40:
        return None
    senses = item.get("senses") or []
    # Böjningsformer och stavningsvarianter har inga egna uppgifter.
    real = [sense for sense in senses if "form_of" not in sense and "alt_of" not in sense]
    if senses and not real:
        return None
    glosses = []
    for sense in real:
        for gloss in (sense.get("glosses") or [])[:1]:
            if gloss and gloss not in glosses:
                glosses.append(gloss)
    ipa = next((sound["ipa"] for sound in item.get("sounds") or [] if sound.get("ipa")), "")
    etymology = swedish_etymology(item.get("etymology_text") or "")
    if not (etymology or ipa or glosses):
        return None
    return [word, item.get("pos") or "", etymology, ipa, glosses[:6]]


def read_kaikki_sv(sources_dir, stats, user_agent, url=KAIKKI_SV_URL):
    """De svenska orden ur Wiktionary, strömmade och filtrerade. Tom lista om källan inte går att nå,
    så att ordboken ändå byggs (utan ursprung och uttal)."""
    path = os.path.join(sources_dir, FILTERED_NAME)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, encoding="utf-8") as file:
            entries = json.load(file)
        log(f"  wiktionary: finns redan ({len(entries)} ord)")
        return entries
    for attempt in range(2):
        entries = []
        lines = 0
        started = time.time()
        try:
            log(f"  wiktionary: strömmar {url}")
            request = urllib.request.Request(url, headers={"User-Agent": user_agent})
            with urllib.request.urlopen(request, timeout=300) as response:
                for raw in response:
                    lines += 1
                    try:
                        item = json.loads(raw)
                    except ValueError:
                        continue
                    entry = _entry(item)
                    if entry:
                        entries.append(entry)
            log(f"  wiktionary: {lines} rader på {time.time() - started:.0f} s, {len(entries)} ord kvar")
            os.makedirs(sources_dir, exist_ok=True)
            with open(path + ".part", "w", encoding="utf-8") as file:
                json.dump(entries, file, ensure_ascii=False)
            os.replace(path + ".part", path)
            stats["wiktionary rader i källan"] = lines
            return entries
        except Exception as error:  # noqa: BLE001 (ett nytt försök, sedan utan källan)
            log(f"  wiktionary: försök {attempt + 1} misslyckades efter {lines} rader: {error}")
            time.sleep(5)
    stats["wiktionary saknas"] = 1
    return []


def build_tables(entries, sv_lemmas, en_lemmas, en_sv_pairs, stats):
    """Raderna till sv_wiktionary (lemma, ipa, ursprung) och en_sv_wiktionary (engelskt ord, ordklass,
    rank, svenskt ord). `en_lemmas`: (normaliserat engelskt ord, ordklass) i WordNet. `en_sv_pairs`:
    (normaliserat engelskt ord, svenskt ord) som Folkets lexikon redan har, de tas inte med igen."""
    sv_rows = {}
    translations = {}
    for word, pos, etymology, ipa, glosses in entries:
        if word not in sv_lemmas:
            continue
        current = sv_rows.get(word, ["", ""])
        sv_rows[word] = [current[0] or ipa, current[1] or etymology]
        en_pos = EN_POS.get(pos)
        if not en_pos:
            continue
        for gloss in glosses:
            for candidate in _gloss_words(gloss, en_pos):
                if (candidate, en_pos) not in en_lemmas or (candidate, word) in en_sv_pairs:
                    continue
                if candidate == word.lower():
                    # Samma ord på båda språken (abbot, abort) ger ingen ny översättning.
                    continue
                listed = translations.setdefault((candidate, en_pos), [])
                if word not in listed and len(listed) < MAX_TRANSLATIONS:
                    listed.append(word)
    sv_table = sorted((lemma, ipa, ety) for lemma, (ipa, ety) in sv_rows.items() if ipa or ety)
    en_table = sorted((en, pos, rank, sv) for (en, pos), words in translations.items()
                      for rank, sv in enumerate(words))
    stats["rader sv_wiktionary"] = len(sv_table)
    stats["sv_wiktionary med ursprung"] = sum(1 for row in sv_table if row[2])
    stats["sv_wiktionary med uttal"] = sum(1 for row in sv_table if row[1])
    stats["rader en_sv_wiktionary"] = len(en_table)
    return sv_table, en_table


def _gloss_words(gloss, en_pos):
    """Engelska ord i en förklaring som "free, without charge" eller "to strike, hit"."""
    gloss = re.sub(r"\([^)]*\)", "", gloss)
    words = []
    for part in re.split(r"[,;]", gloss):
        part = part.strip().lower()
        if en_pos == "v" and part.startswith("to "):
            part = part[3:]
        if en_pos == "n":
            part = re.sub(r"^(a|an|the) ", "", part)
        if part and re.fullmatch(r"[a-z][a-z'\-]*", part):
            words.append(part)
    return words
