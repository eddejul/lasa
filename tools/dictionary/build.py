#!/usr/bin/env python
"""Bygger Läsas ordboksdatabas (SQLite) från öppna källor.

Källor (se SOURCES nedan och README.md):
  * Folkets synonymlexikon Synlex (KTH), svenska synonympar med betyg
  * wordfreq (Robyn Speer), hur vanliga orden är, CC BY-SA 4.0
  * Swesaurus (Språkbanken), som delar upp Synlex-paren per betydelse, CC BY 4.0
  * SALDO och SALDO morfologi (Språkbanken), betydelser och böjningsformer, CC BY 4.0
  * Open English WordNet 2025, engelska synonymer och definitioner, CC BY 4.0
  * Folkets lexikon (KTH), engelska till svenska och svenska definitioner, CC BY-SA 2.5
  * Wiktionary via kaikki.org (O10), ursprung, uttal och fler översättningar, CC BY-SA 4.0. Strömmas och
    filtreras i bygget, se wiktionary.py. Rådata sparas aldrig.

Användning:
  python tools/dictionary/build.py                 # laddar ner till sources/, bygger out/lasa-ordbok.sqlite
  python tools/dictionary/build.py --out x.sqlite --report rapport.txt

Svenska Akademiens data (SO, SAOL) används aldrig här. Den visas bara via svenska.se i appen.
Samma databasfil ska fungera i Windows-appen (fas 5), så schemat är vanlig SQLite utan tillägg.
"""

import argparse
import datetime
import gzip
import hashlib
import html
import os
import re
import sqlite3
import sys
import time
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))

# Höj när schemat eller tolkningen ändras på ett sätt som appen behöver veta om.
SCHEMA_VERSION = 2

SOURCES = {
    "synlex": "https://folkets-lexikon.csc.kth.se/lexikon/synpairs.xml",
    "swesaurus": "https://svn.spraakbanken.gu.se/sb-arkiv/pub/lmf/swesaurus/swesaurus.xml",
    "saldo": "https://svn.spraakbanken.gu.se/sb-arkiv/pub/lmf/saldo/saldo.xml",
    "saldom": "https://svn.spraakbanken.gu.se/sb-arkiv/pub/lmf/saldom/saldom.xml",
    "oewn": "https://github.com/globalwordnet/english-wordnet/releases/download/2025-edition/english-wordnet-2025.xml.gz",
    "folkets_en_sv": "https://folkets-lexikon.csc.kth.se/folkets/folkets_en_sv_public.xml",
    "folkets_sv_en": "https://folkets-lexikon.csc.kth.se/folkets/folkets_sv_en_public.xml",
}

# Vanligheten kommer från wordfreq, som installeras i bygget (pip install wordfreq==3.1.1).
WORDFREQ_VERSION = "3.1.1"

# Specen: visa bara synonympar med betyg 3 eller högre på Synlex femgradiga skala.
# Synlex-filen innehåller redan bara par från 3,0, men gränsen ligger här så att den kan höjas.
MIN_SCORE = 3.0

# Swesaurus (2017) har Synlex-paren uppdelade per SALDO-betydelse. Källan fsl är ett par ur Synlex,
# dfsl ett par som Swesaurus själv har räknat fram. Bara par som också finns i Synlex används,
# Swesaurus bestämmer bara vilken betydelse paret hör till. Övriga källor (wiktionary, pwn) har inga
# betyg och gav fel som "giltig" och "ogiltig" som synonymer, så de används inte.
SENSE_SOURCES = {"fsl", "dfsl"}

# SALDO-ordklasser som tas med. Egennamn (pm), flerordsuttryck (slutar på m) och
# sammansättningsled (mxc, sxc) tas bort för att hålla nere storleken.
SV_POS = {"nn", "vb", "av", "ab", "pp", "pn", "kn", "sn", "in", "nl", "al", "ie"}
# Samma ordning som appen visar ordklasserna i, när ett ord kan vara flera.
SV_POS_ORDER = ["vb", "nn", "av", "ab", "pp", "kn", "sn", "pn", "nl", "in", "al", "ie"]
# Böjningsformer som bara används inne i sammansättningar.
SV_COMPOUND_MSD = {"c", "ci", "cm", "sms"}

OEWN_POS = {"n": "n", "v": "v", "a": "a", "s": "a", "r": "r"}
FOLKETS_POS = {"nn": "n", "vb": "v", "jj": "a", "ab": "r"}
# Folkets svensk-engelska del: ordklass till SALDO:s koder, och till engelska koder för omvända översättningar.
FOLKETS_SV_POS = {"nn": "nn", "vb": "vb", "jj": "av", "pc": "av", "ab": "ab", "pp": "pp", "pn": "pn",
                  "kn": "kn", "sn": "sn", "in": "in", "rg": "nl", "ie": "ie", "article": "al"}
FOLKETS_SV_TO_EN = {"nn": "n", "vb": "v", "jj": "a", "pc": "a", "ab": "r"}
# Omvända översättningar (ur den svensk-engelska delen) får rank från och med det här, efter Folkets egna.
REVERSED_RANK = 500

USER_AGENT = "Lasa-ordbok-bygge/1 (+https://github.com/eddejul/lasa)"


def log(message):
    print(message, flush=True)


def normalize(word):
    """Samma normalisering som appen: NFKC (ligaturer som fi blir två bokstäver), raka apostrofer, gemener."""
    word = unicodedata.normalize("NFKC", word).replace("’", "'").replace("­", "")
    return word.strip().lower()


def frequency_lookup(language):
    """Hur vanligt ett ord är på Zipf-skalan (0 till 8, vanliga ord ligger runt 4 till 6)."""
    try:
        from wordfreq import zipf_frequency
    except ImportError:
        raise SystemExit(f"wordfreq saknas: pip install wordfreq=={WORDFREQ_VERSION}")
    cache = {}

    def frequency(word):
        if word not in cache:
            cache[word] = round(zipf_frequency(word, language), 2)
        return cache[word]
    return frequency


def is_single_token(word):
    return bool(word) and " " not in word and not word.startswith("-") and not word.endswith("-")


def base_pos(pos):
    """SALDO: vbm (flerordsverb) och vba (förkortning) räknas som vb."""
    return (pos or "")[:2]


def sense_word(sense_id):
    """lämna..2 blir lämna, byta_ut..1 blir byta ut."""
    return sense_id.rsplit("..", 1)[0].replace("_", " ")


# MARK: Nedladdning


def download(name, url, directory):
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, url.rsplit("/", 1)[-1])
    if os.path.exists(path) and os.path.getsize(path) > 0:
        log(f"  {name}: finns redan ({os.path.getsize(path) / 1e6:.1f} MB)")
        return path
    log(f"  {name}: laddar ner {url}")
    temp = path + ".part"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=120) as response, open(temp, "wb") as out:
                while True:
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    out.write(chunk)
            os.replace(temp, path)
            log(f"  {name}: klar ({os.path.getsize(path) / 1e6:.1f} MB)")
            return path
        except Exception as error:  # noqa: BLE001 (vi försöker igen)
            log(f"  {name}: försök {attempt + 1} misslyckades: {error}")
            time.sleep(5 * (attempt + 1))
    raise SystemExit(f"Kunde inte ladda ner {url}")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# MARK: XML


def iter_elements(path, tags):
    """Går igenom stora XML-filer element för element och släpper varje element efteråt."""
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rb") as file:
        parents = []
        for event, element in ET.iterparse(file, events=("start", "end")):
            if event == "start":
                parents.append(element)
                continue
            parents.pop()
            if element.tag in tags:
                yield element
                if parents:
                    parents[-1].remove(element)
                element.clear()


def feats(element):
    """LMF: <feat att="x" val="y"/> som en ordlista."""
    return {feat.get("att"): feat.get("val") for feat in element.findall("feat")}


# MARK: Svenska


def read_saldo_senses(path):
    """(grundform, ordklass) till sina betydelser, i SALDO:s ordning (lämna..1, lämna..2)."""
    lemma_senses = defaultdict(list)
    for entry in iter_elements(path, {"LexicalEntry"}):
        lemmas = []
        lemma = entry.find("Lemma")
        if lemma is not None:
            for representation in lemma.findall("FormRepresentation"):
                f = feats(representation)
                form, pos = f.get("writtenForm"), f.get("partOfSpeech")
                if form and pos and (form, pos) not in lemmas:
                    lemmas.append((form, pos))
        for sense in entry.findall("Sense"):
            sense_id = sense.get("id")
            if not sense_id:
                continue
            for item in lemmas:
                if sense_id not in lemma_senses[item]:
                    lemma_senses[item].append(sense_id)
    return lemma_senses


def read_synlex(path, stats):
    """Ordpar till betyg (1 till 5). Paren gäller åt båda hållen, det högsta betyget används."""
    pairs = defaultdict(dict)
    for syn in iter_elements(path, {"syn"}):
        w1, w2 = syn.findtext("w1"), syn.findtext("w2")
        try:
            level = float(syn.get("level", "0"))
        except ValueError:
            continue
        if not w1 or not w2 or w1 == w2:
            continue
        w1, w2 = w1.strip(), w2.strip()
        for a, b in ((w1, w2), (w2, w1)):
            pairs[a][b] = max(level, pairs[a].get(b, 0))
    stats["synlex ord"] = len(pairs)
    return pairs


def read_swesaurus(path, stats):
    """Betydelse till de synonymord den är kopplad till: {lämna..2: {avgå: 80}}."""
    sense_targets = defaultdict(dict)
    for entry in iter_elements(path, {"LexicalEntry"}):
        for sense in entry.findall("Sense"):
            source_id = sense.get("id")
            for relation in sense.findall("SenseRelation"):
                f = feats(relation)
                label, source = f.get("label"), f.get("source", "")
                stats[f"swesaurus {label} {source}"] += 1
                target = relation.get("targets")
                if label != "syn" or source not in SENSE_SOURCES or not target or not source_id:
                    continue
                word = sense_word(target)
                degree = int(f.get("degree", "0"))
                sense_targets[source_id][word] = max(degree, sense_targets[source_id].get(word, 0))
    return sense_targets


def read_saldom_forms(path, stats):
    rows = set()
    for entry in iter_elements(path, {"LexicalEntry"}):
        lemma = entry.find("Lemma")
        if lemma is None:
            continue
        representation = lemma.find("FormRepresentation")
        if representation is None:
            continue
        f = feats(representation)
        base, pos = f.get("writtenForm"), f.get("partOfSpeech")
        stats[f"saldom ordklass {pos}"] += 1
        if not base or pos not in SV_POS or " " in base:
            continue
        rows.add((normalize(base), base, pos))
        for word_form in entry.findall("WordForm"):
            wf = feats(word_form)
            form, msd = wf.get("writtenForm"), wf.get("msd", "")
            if not form or msd in SV_COMPOUND_MSD or not is_single_token(form):
                continue
            rows.add((normalize(form), base, pos))
    return rows


def build_sv_synonyms(sv_forms, lemma_senses, synlex, sense_targets, stats):
    """Synlex-paren, med betydelse från Swesaurus där den finns.

    Ett par hamnar under den betydelse som Swesaurus kopplar det till. Har ordet bara en betydelse
    i SALDO hamnar det där. Annars läggs paret i en grupp utan betydelse (sense_id tom), som appen
    visar sist. En synonym måste ha samma ordklass som ordet (Synlex har till exempel "ersätta" och
    "byte" som par, men byte är ett substantiv).
    """
    base_pos_of = defaultdict(set)  # grundform till ordklasser
    lemmas_of_form = defaultdict(set)  # normaliserad form till (grundform, ordklass)
    for form, base, pos in sv_forms:
        base_pos_of[base].add(pos)
        lemmas_of_form[form].add((base, pos))

    def fitted_synonym(synonym, lemma, pos):
        """Synonymen som den ska visas, eller None om den inte passar.

        En böjd form byts mot sin grundform (Synlex har "korrekt" och "riktigt"), en form av ordet
        självt tas bort ("brista" och "brister"). Substantiv och verb blandas inte ("brist" och "saknar"),
        men adjektiv får ha particip som synonym ("giltig" och "gällande").
        """
        words = synonym.split(" ")
        found = lemmas_of_form.get(normalize(words[0]), set())
        same = [base for base, p in found if p == pos]
        if same:
            if len(words) > 1 or synonym in same:
                return synonym
            base = sorted(same)[0]
            return None if normalize(base) == normalize(lemma) else base
        other = {p for _base, p in found}
        if pos in ("nn", "vb") and other and other <= {"nn", "vb"}:
            return None
        return synonym

    def has_exact_pos(synonym, pos):
        return any(p == pos for _base, p in lemmas_of_form.get(normalize(synonym.split(" ")[0]), set()))

    def pos_rank(pos):
        return SV_POS_ORDER.index(pos) if pos in SV_POS_ORDER else 99

    # Synlex-paren gäller ord, inte ordklasser. Ett ord som "springa" (verb och substantiv) får
    # därför varje par placerat i en ordklass: där Swesaurus lägger det, annars där synonymen har
    # samma ordklass, annars i ordets vanligaste ordklass (den med flest par med känd betydelse).
    rows = {}
    for lemma, poses in base_pos_of.items():
        synonyms = synlex.get(lemma)
        if not synonyms:
            continue
        sensed = Counter()
        placements = []
        for raw, level in synonyms.items():
            if level < MIN_SCORE:
                continue
            best = None  # (grad, ordklass, betydelse, synonym)
            fitted = {}
            for pos in poses:
                synonym = fitted_synonym(raw, lemma, pos)
                if synonym is None:
                    continue
                fitted[pos] = synonym
                for sense_id in lemma_senses.get((lemma, pos), []):
                    targets = sense_targets.get(sense_id, {})
                    degree = max(targets.get(synonym, -1), targets.get(raw, -1))
                    if degree >= 0 and (best is None or degree > best[0]):
                        best = (degree, pos, sense_id, synonym)
            if not fitted:
                stats["sv synonym med fel ordklass eller samma ord"] += 1
                continue
            if best:
                sensed[best[1]] += 1
                placements.append((best[1], best[2], best[3], level))
            else:
                placements.append((None, fitted, raw, level))

        for pos, sense_or_fitted, synonym, level in placements:
            if pos is None:
                fitted = sense_or_fitted
                exact = [p for p in fitted if has_exact_pos(fitted[p], p)]
                choices = exact or list(fitted)
                pos = min(choices, key=lambda p: (-sensed[p], pos_rank(p)))
                synonym = fitted[pos]
                senses = lemma_senses.get((lemma, pos), [])
                sense_id = senses[0] if len(senses) == 1 else ""
                stats["sv par i ordets enda betydelse" if sense_id else "sv par utan betydelse"] += 1
            else:
                sense_id = sense_or_fitted
                stats["sv par med betydelse från swesaurus"] += 1
            if normalize(synonym) == normalize(lemma):
                continue
            key = (lemma, pos, sense_id, synonym)
            rows[key] = max(rows.get(key, 0), level)
    return [key + (level,) for key, level in rows.items()]


# MARK: Engelska


def read_oewn(path, stats):
    entries = {}
    synsets = {}
    for element in iter_elements(path, {"LexicalEntry", "Synset"}):
        if element.tag == "LexicalEntry":
            lemma = element.find("Lemma")
            if lemma is None:
                continue
            word = lemma.get("writtenForm")
            pos = OEWN_POS.get(lemma.get("partOfSpeech"))
            if not word or not pos:
                continue
            forms = [form.get("writtenForm") for form in element.findall("Form") if form.get("writtenForm")]
            senses = [sense.get("synset") for sense in element.findall("Sense") if sense.get("synset")]
            entries[element.get("id")] = (word, pos, forms, senses)
        else:
            definition = element.find("Definition")
            members = (element.get("members") or "").split()
            synsets[element.get("id")] = ((definition.text or "").strip() if definition is not None else "", members)
    stats["oewn uppslag"] = len(entries)
    stats["oewn synset"] = len(synsets)
    return entries, synsets


def read_folkets(path, stats):
    translations = []
    forms = set()
    rank = Counter()
    for word in iter_elements(path, {"word"}):
        value = html.unescape(word.get("value") or "").strip()
        pos = FOLKETS_POS.get(word.get("class"), word.get("class") or "")
        if not value:
            continue
        key = normalize(value)
        if is_single_token(value):
            forms.add((key, value, pos))
        paradigm = word.find("paradigm")
        if paradigm is not None:
            for inflection in paradigm.findall("inflection"):
                form = html.unescape(inflection.get("value") or "").strip()
                if is_single_token(form):
                    forms.add((normalize(form), value, pos))
        for translation in word.findall("translation"):
            sv = html.unescape(translation.get("value") or "").strip()
            # Tomma översättningar och hänvisningar som "se grant" visas inte.
            if not sv or (sv.startswith("se ") and " " not in sv[3:].strip()):
                stats["folkets hänvisningar och tomma"] += 1
                continue
            comment = html.unescape(translation.get("comment") or "").strip()
            translations.append((key, rank[key], sv, pos, comment))
            rank[key] += 1
    stats["folkets översättningar"] = len(translations)
    return translations, forms


def read_folkets_sv(path, stats):
    """Svenska definitioner per SALDO-betydelse, och engelska ord med svensk översättning (omvänt).

    Folkets svensk-engelska del har definitioner på enkel svenska för omkring 8 000 betydelser,
    till exempel "springa: ta sig fram genom att röra benen snabbt, löpa", och länkar varje uppslag
    till en SALDO-betydelse. Det engelska ordet i en översättning ger dessutom en svensk översättning
    åt engelska ord som saknas i den engelsk-svenska delen.
    """
    raw = defaultdict(list)  # (ord, ordklass) till [(SALDO-betydelser som uppslaget länkar till, definition)]
    reversed_pairs = []
    for word in iter_elements(path, {"word"}):
        value = html.unescape(word.get("value") or "").strip()
        folkets_class = word.get("class") or ""
        if not value or " " in value:
            continue
        senses = []
        for see in word.findall("see"):
            if see.get("type") == "saldo":
                parts = (see.get("value") or "").split("||")
                if len(parts) >= 2 and parts[1] and parts[1] not in senses:
                    senses.append(parts[1])
        pos = FOLKETS_SV_POS.get(folkets_class)
        if pos:
            for definition in word.findall("definition"):
                text = html.unescape(definition.get("value") or "").strip()
                if text:
                    raw[(value, pos)].append((senses, text))
        english_pos = FOLKETS_SV_TO_EN.get(folkets_class)
        if english_pos:
            for translation in word.findall("translation"):
                english = html.unescape(translation.get("value") or "").strip()
                if is_single_token(english) and english.replace("-", "").replace("'", "").isalpha():
                    reversed_pairs.append((normalize(english), value, english_pos))

    stats["folkets omvända översättningar"] = len(reversed_pairs)
    return raw, reversed_pairs


def assign_definitions(raw, sv_synonyms, stats):
    """Vilken SALDO-betydelse varje definition hör till.

    Ett uppslag i Folkets lexikon kan länka till flera betydelser. Att ta den första lediga gav fel
    ("handling: intrig" hamnade hos betydelsen med synonymen "dokument"). Därför:
    1. Har definitionen ett ord som är synonym i någon av de länkade betydelserna vinner den
       betydelsen ("akt, dokument" hör till betydelsen med synonymen "dokument").
    2. Annars gäller den första länken, om den inte redan har en definition.
    3. Annars blir definitionen en egen betydelse utan SALDO-koppling. Varje betydelse får högst en.
    """
    words_of_sense = defaultdict(set)
    for lemma, pos, sense_id, synonym, _level in sv_synonyms:
        if sense_id:
            for word in synonym.split(" "):
                words_of_sense[(lemma, pos, sense_id)].add(normalize(word))

    definitions = []
    for (value, pos), items in raw.items():
        taken = set()
        seen_texts = set()
        for rank, (senses, text) in enumerate(items):
            if text in seen_texts:
                continue
            seen_texts.add(text)
            tokens = {normalize(t) for t in re.split(r"[^\w]+", text) if t}
            free = [s for s in senses if s not in taken]
            scored = [(len(tokens & words_of_sense.get((value, pos, s), set())), -i, s) for i, s in enumerate(free)]
            best = max(scored, default=None)
            if best and best[0] > 0:
                sense_id = best[2]
                stats["sv definition placerad efter synonym"] += 1
            elif senses and senses[0] not in taken:
                sense_id = senses[0]
                stats["sv definition placerad efter första länken"] += 1
            else:
                sense_id = ""
                stats["sv definition utan betydelse"] += 1
            if sense_id:
                taken.add(sense_id)
            definitions.append((value, pos, sense_id, rank, text))
    stats["folkets svenska definitioner"] = len(definitions)
    return definitions


# MARK: Databasen

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;

-- Böjd form (normaliserad: gemener, NFKC) till grundform och ordklass (SALDO-koder).
CREATE TABLE sv_forms (form TEXT NOT NULL, lemma TEXT NOT NULL, pos TEXT NOT NULL,
                       PRIMARY KEY (form, lemma, pos)) WITHOUT ROWID;
-- Synonymer per betydelse (SALDO-betydelse som lämna..2, tom när betydelsen är okänd).
-- score är Synlex-betyget 3 till 5, freq hur vanlig synonymen är (Zipf, wordfreq).
CREATE TABLE sv_synonyms (lemma TEXT NOT NULL, pos TEXT NOT NULL, sense_id TEXT NOT NULL,
                          synonym TEXT NOT NULL, score REAL NOT NULL, freq REAL NOT NULL,
                          PRIMARY KEY (lemma, pos, sense_id, synonym)) WITHOUT ROWID;
-- Definitioner på enkel svenska ur Folkets lexikon, per SALDO-betydelse (tom när den är okänd).
CREATE TABLE sv_definitions (lemma TEXT NOT NULL, pos TEXT NOT NULL, sense_id TEXT NOT NULL,
                             rank INTEGER NOT NULL, definition TEXT NOT NULL,
                             PRIMARY KEY (lemma, pos, rank)) WITHOUT ROWID;

-- Engelska: form till grundform. Reguljära böjningar (dogs, walked) hittas med reglerna i README.md.
CREATE TABLE en_forms (form TEXT NOT NULL, lemma TEXT NOT NULL, pos TEXT NOT NULL,
                       PRIMARY KEY (form, lemma, pos)) WITHOUT ROWID;
-- Betydelser i ordning (vanligast först). pos: n, v, a, r.
CREATE TABLE en_senses (lemma TEXT NOT NULL, synset_id TEXT NOT NULL, pos TEXT NOT NULL, rank INTEGER NOT NULL,
                        PRIMARY KEY (lemma, synset_id)) WITHOUT ROWID;
CREATE TABLE en_synsets (synset_id TEXT PRIMARY KEY, definition TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE en_synset_members (synset_id TEXT NOT NULL, lemma TEXT NOT NULL, rank INTEGER NOT NULL,
                                freq REAL NOT NULL, PRIMARY KEY (synset_id, lemma)) WITHOUT ROWID;
-- Engelska till svenska. en_lemma är normaliserad (gemener). rank i lexikonets ordning, och från 500
-- för omvända översättningar ur den svensk-engelska delen (används bara när ordet saknar egna).
CREATE TABLE en_sv (en_lemma TEXT NOT NULL, rank INTEGER NOT NULL, sv TEXT NOT NULL, pos TEXT NOT NULL,
                    comment TEXT NOT NULL, PRIMARY KEY (en_lemma, rank)) WITHOUT ROWID;

-- Ur Wiktionary via kaikki.org (O10, CC BY-SA 4.0). Uttal (IPA) och ursprung för svenska grundformer,
-- ursprunget kortat till en mening och delvis översatt till svenska.
CREATE TABLE sv_wiktionary (lemma TEXT PRIMARY KEY, ipa TEXT NOT NULL, etymology TEXT NOT NULL) WITHOUT ROWID;
-- Fler svenska översättningar av engelska ord: svenska ord vars engelska förklaring är det engelska ordet.
-- Bara par som Folkets lexikon inte redan har. en_lemma är normaliserad, pos som i en_senses.
CREATE TABLE en_sv_wiktionary (en_lemma TEXT NOT NULL, pos TEXT NOT NULL, rank INTEGER NOT NULL, sv TEXT NOT NULL,
                               PRIMARY KEY (en_lemma, pos, rank)) WITHOUT ROWID;
"""


def build(sources_dir, out_path, stats):
    log("Laddar ner källorna")
    paths = {name: download(name, url, sources_dir) for name, url in SOURCES.items()}
    checksums = {name: sha256(path) for name, path in paths.items()}

    log("Läser SALDO morfologi (böjningsformer)")
    sv_forms = read_saldom_forms(paths["saldom"], stats)
    log(f"  {len(sv_forms)} svenska former")

    log("Läser SALDO (betydelser), Swesaurus och Synlex")
    lemma_senses = read_saldo_senses(paths["saldo"])
    sense_targets = read_swesaurus(paths["swesaurus"], stats)
    synlex = read_synlex(paths["synlex"], stats)
    sv_synonyms = build_sv_synonyms(sv_forms, lemma_senses, synlex, sense_targets, stats)
    del lemma_senses, sense_targets, synlex
    log(f"  {len(sv_synonyms)} svenska synonympar")

    log("Läser Open English WordNet")
    entries, synsets = read_oewn(paths["oewn"], stats)

    log("Läser Folkets lexikon")
    en_sv, folkets_forms = read_folkets(paths["folkets_en_sv"], stats)
    raw_definitions, reversed_pairs = read_folkets_sv(paths["folkets_sv_en"], stats)
    sv_definitions = assign_definitions(raw_definitions, sv_synonyms, stats)
    seen_translations = {(key, sv, pos) for key, _rank, sv, pos, _comment in en_sv}
    reversed_rank = Counter()
    for key, sv, pos in reversed_pairs:
        if (key, sv, pos) in seen_translations:
            continue
        seen_translations.add((key, sv, pos))
        en_sv.append((key, REVERSED_RANK + reversed_rank[key], sv, pos, ""))
        reversed_rank[key] += 1

    en_forms = set(folkets_forms)
    en_senses = {}
    entry_lemma = {}
    used_synsets = set()
    for entry_id, (word, pos, forms, sense_list) in entries.items():
        entry_lemma[entry_id] = word
        if not is_single_token(word):
            continue
        en_forms.add((normalize(word), word, pos))
        for form in forms:
            if is_single_token(form):
                en_forms.add((normalize(form), word, pos))
        for rank, synset_id in enumerate(sense_list):
            # Samma lemma kan ha flera uppslag med samma synset (sällsynt). Första gäller.
            en_senses.setdefault((word, synset_id), (word, synset_id, pos, rank))
            used_synsets.add(synset_id)
    en_synsets = []
    en_members = []
    for synset_id in used_synsets:
        definition, members = synsets.get(synset_id, ("", []))
        en_synsets.append((synset_id, definition))
        seen = set()
        for rank, member in enumerate(members):
            lemma = entry_lemma.get(member)
            if lemma and lemma not in seen:
                seen.add(lemma)
                en_members.append((synset_id, lemma, rank))
    en_senses = list(en_senses.values())

    log("Läser Wiktionary (kaikki.org)")
    import wiktionary  # noqa: E402 (ligger bredvid)
    kaikki = wiktionary.read_kaikki_sv(sources_dir, stats, USER_AGENT)
    sv_lemmas = {lemma for _form, lemma, _pos in sv_forms}
    en_lemmas = {(normalize(word), pos) for word, _synset, pos, _rank in en_senses}
    en_sv_pairs = {(key, sv) for key, _rank, sv, _pos, _comment in en_sv}
    sv_wiktionary, en_sv_wiktionary = wiktionary.build_tables(kaikki, sv_lemmas, en_lemmas, en_sv_pairs, stats)
    del kaikki
    log(f"  {len(sv_wiktionary)} svenska ord med uttal eller ursprung, {len(en_sv_wiktionary)} fler översättningar")

    log("Räknar ut hur vanliga synonymerna är (wordfreq)")
    sv_frequency = frequency_lookup("sv")
    en_frequency = frequency_lookup("en")
    sv_synonyms = [row + (sv_frequency(row[3]),) for row in sv_synonyms]
    en_members = [(synset_id, lemma, rank, en_frequency(lemma)) for synset_id, lemma, rank in en_members]

    log("Skriver databasen")
    if os.path.exists(out_path):
        os.remove(out_path)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    db = sqlite3.connect(out_path)
    db.execute("PRAGMA page_size = 4096")
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO sv_forms VALUES (?, ?, ?)", sorted(sv_forms))
    db.executemany("INSERT INTO sv_synonyms VALUES (?, ?, ?, ?, ?, ?)", sorted(sv_synonyms))
    db.executemany("INSERT INTO sv_definitions VALUES (?, ?, ?, ?, ?)", sorted(sv_definitions))
    db.executemany("INSERT INTO en_forms VALUES (?, ?, ?)", sorted(en_forms))
    db.executemany("INSERT INTO en_senses VALUES (?, ?, ?, ?)", sorted(en_senses))
    db.executemany("INSERT INTO en_synsets VALUES (?, ?)", sorted(en_synsets))
    db.executemany("INSERT INTO en_synset_members VALUES (?, ?, ?, ?)", sorted(en_members))
    db.executemany("INSERT INTO en_sv VALUES (?, ?, ?, ?, ?)", en_sv)
    db.executemany("INSERT INTO sv_wiktionary VALUES (?, ?, ?)", sv_wiktionary)
    db.executemany("INSERT INTO en_sv_wiktionary VALUES (?, ?, ?, ?)", en_sv_wiktionary)

    meta = {
        "schema_version": str(SCHEMA_VERSION),
        "built": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
        "min_score": str(MIN_SCORE),
        "wordfreq": WORDFREQ_VERSION,
    }
    for name, url in SOURCES.items():
        meta[f"source.{name}.url"] = url
        meta[f"source.{name}.sha256"] = checksums[name]
    meta["source.wiktionary.url"] = wiktionary.KAIKKI_SV_URL
    db.executemany("INSERT INTO meta VALUES (?, ?)", sorted(meta.items()))
    db.commit()
    db.execute("ANALYZE")
    db.commit()
    db.execute("VACUUM")
    db.close()

    for table, rows in [("sv_forms", sv_forms), ("sv_synonyms", sv_synonyms),
                        ("sv_definitions", sv_definitions), ("en_forms", en_forms),
                        ("en_senses", en_senses), ("en_synsets", en_synsets),
                        ("en_synset_members", en_members), ("en_sv", en_sv)]:
        stats[f"rader {table}"] = len(rows)
    stats["storlek MB"] = round(os.path.getsize(out_path) / 1e6, 1)
    return checksums


def main():
    parser = argparse.ArgumentParser(description="Bygger Läsas ordbok.")
    parser.add_argument("--sources", default=os.path.join(HERE, "sources"))
    parser.add_argument("--out", default=os.path.join(HERE, "out", "lasa-ordbok.sqlite"))
    parser.add_argument("--report", default=os.path.join(HERE, "out", "testrapport.txt"))
    parser.add_argument("--max-mb", type=float, default=80)
    args = parser.parse_args()

    started = time.time()
    stats = Counter()
    checksums = build(args.sources, args.out, stats)

    import report  # noqa: E402 (ligger bredvid)
    report.write_report(args.out, os.path.join(HERE, "testwords.txt"), args.report, stats, checksums)
    log(f"Klart på {time.time() - started:.0f} s: {args.out} ({stats['storlek MB']} MB), rapport i {args.report}")
    if stats["storlek MB"] > args.max_mb:
        raise SystemExit(f"Databasen är {stats['storlek MB']} MB, mer än målet {args.max_mb} MB.")


if __name__ == "__main__":
    sys.path.insert(0, HERE)
    main()
