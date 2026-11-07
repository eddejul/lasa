"""Uppslag i ordboksdatabasen, på samma sätt som appen gör (App/Dictionary/Dictionary.swift).

Ändras logiken här ska den ändras i appen också, och tvärtom. Rapporten (report.py) använder
den här filen, så testlistan visar exakt vad appen visar.

  python tools/dictionary/lookup.py out/lasa-ordbok.sqlite sprang went arbetslösheten
"""

import sqlite3
import sys
import unicodedata

SV_POS_NAMES = {
    "nn": "substantiv", "vb": "verb", "av": "adjektiv", "ab": "adverb", "pp": "preposition",
    "pn": "pronomen", "kn": "konjunktion", "sn": "subjunktion", "in": "interjektion",
    "nl": "räkneord", "al": "artikel", "ie": "infinitivmärke",
}
EN_POS_NAMES = {
    "n": "substantiv", "v": "verb", "a": "adjektiv", "r": "adverb", "pp": "preposition",
    "pn": "pronomen", "kn": "konjunktion", "in": "interjektion", "rg": "räkneord",
    "article": "artikel", "abbrev": "förkortning", "pc": "particip", "ie": "infinitivmärke",
}
# Ordklasser i den ordning de visas när ett ord kan vara flera.
SV_POS_ORDER = ["vb", "nn", "av", "ab", "pp", "kn", "sn", "pn", "nl", "in", "al", "ie"]
EN_POS_ORDER = ["v", "n", "a", "r"]

# Reglerna för engelska böjningar, som WordNets morphy. (ändelse, ersättning, ordklass)
EN_RULES = [
    ("s", "", "n"), ("ses", "s", "n"), ("xes", "x", "n"), ("zes", "z", "n"), ("ches", "ch", "n"),
    ("shes", "sh", "n"), ("men", "man", "n"), ("ies", "y", "n"),
    ("s", "", "v"), ("ies", "y", "v"), ("es", "e", "v"), ("es", "", "v"), ("ed", "e", "v"),
    ("ed", "", "v"), ("ing", "e", "v"), ("ing", "", "v"),
    ("er", "", "a"), ("est", "", "a"), ("er", "e", "a"), ("est", "e", "a"), ("ier", "y", "a"), ("iest", "y", "a"),
]

MAX_SENSES = 8
MAX_SYNONYMS = 12
MAX_TRANSLATIONS = 8


def normalize(word):
    word = unicodedata.normalize("NFKC", word).replace("’", "'").replace("­", "")
    word = word.strip().lower()
    # Bort med skiljetecken runt ordet, men inte inne i det (e-post, don't).
    while word and not word[0].isalnum():
        word = word[1:]
    while word and not word[-1].isalnum():
        word = word[:-1]
    return word


def _sense_number(sense_id):
    """Ordning för betydelserna. Par utan känd betydelse (tom sense_id) kommer sist."""
    try:
        return int(sense_id.rsplit("..", 1)[1])
    except (IndexError, ValueError):
        return 10_000


class Dictionary:

    def __init__(self, path):
        self.db = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)

    # MARK: Svenska

    def sv_lemmas(self, key):
        return self.db.execute("SELECT lemma, pos FROM sv_forms WHERE form = ?", (key,)).fetchall()

    def sv_entry(self, lemma, pos, hidden=frozenset()):
        rows = self.db.execute(
            "SELECT sense_id, synonym, score FROM sv_synonyms WHERE lemma = ? AND pos = ?", (lemma, pos)
        ).fetchall()
        senses = {}
        for sense_id, synonym, score in rows:
            if (lemma, synonym) in hidden:
                continue
            senses.setdefault(sense_id, []).append((synonym, score))
        ordered = []
        for sense_id in sorted(senses, key=_sense_number):
            synonyms = sorted(senses[sense_id], key=lambda item: (-item[1], item[0]))
            ordered.append((sense_id, synonyms[:MAX_SYNONYMS]))
        return {"lemma": lemma, "pos": pos, "pos_name": SV_POS_NAMES.get(pos, ""), "senses": ordered[:MAX_SENSES]}

    def lookup_sv(self, word, hidden=frozenset()):
        key = normalize(word)
        if not key:
            return None
        lemmas = self.sv_lemmas(key)
        compound = None
        if not lemmas:
            compound = self.split_compound(key)
            if compound:
                lemmas = self.sv_lemmas(compound[1])
        if not lemmas:
            return None
        entries = [self.sv_entry(lemma, pos, hidden) for lemma, pos in lemmas]

        def order(entry):
            # Ord med synonymer först, sedan grundformen själv, sedan flest synonymer (ett mått på
            # hur vanlig ordklassen är), sedan ordklassernas fasta ordning.
            return (not entry["senses"],
                    normalize(entry["lemma"]) != key,
                    -sum(len(synonyms) for _sense, synonyms in entry["senses"]),
                    SV_POS_ORDER.index(entry["pos"]) if entry["pos"] in SV_POS_ORDER else 99,
                    entry["lemma"])
        entries.sort(key=order)
        return {"language": "sv", "word": word, "key": key, "compound": compound, "entries": entries}

    def split_compound(self, key):
        """Sammansatta ord som inte finns i SALDO, som kurslitteraturläsning: kurslitteratur + läsning.

        Efterledet (det sista ordet) bestämmer betydelsen. Det längsta efterledet som finns,
        med ett förled som också finns (eventuellt med foge-s), vinner.
        """
        if len(key) < 7:
            return None
        for split in range(3, len(key) - 3):
            head, tail = key[:split], key[split:]
            if not self.sv_lemmas(tail):
                continue
            if self.sv_lemmas(head) or (head.endswith("s") and len(head) > 3 and self.sv_lemmas(head[:-1])):
                return (head, tail)
        return None

    # MARK: Engelska

    def en_candidates(self, key):
        """(grundform, ordklass) för en engelsk form: först formtabellen, sedan reglerna."""
        found = []

        def add(rows, pos=None):
            for lemma, row_pos in rows:
                if pos and row_pos != pos:
                    continue
                if (lemma, row_pos) not in found:
                    found.append((lemma, row_pos))

        add(self.db.execute("SELECT lemma, pos FROM en_forms WHERE form = ?", (key,)).fetchall())
        base_key = key[:-2] if key.endswith("'s") else key
        if base_key != key:
            add(self.db.execute("SELECT lemma, pos FROM en_forms WHERE form = ?", (base_key,)).fetchall())
        for suffix, replacement, pos in EN_RULES:
            if not base_key.endswith(suffix) or len(base_key) <= len(suffix) + 1:
                continue
            stem = base_key[: -len(suffix)] + replacement
            rows = self.db.execute("SELECT lemma, pos FROM en_forms WHERE form = ?", (stem,)).fetchall()
            if not [r for r in rows if r[1] == pos] and not replacement \
                    and len(stem) > 2 and stem[-1] == stem[-2] and stem[-1] not in "aeiouy":
                # stopped, stopping, bigger: dubbelteckning. Bara om formen utan den inte redan finns (filled).
                rows = self.db.execute("SELECT lemma, pos FROM en_forms WHERE form = ?", (stem[:-1],)).fetchall()
            add(rows, pos)
        return found

    def en_entry(self, lemma, pos, hidden=frozenset()):
        senses = []
        rows = self.db.execute(
            "SELECT s.synset_id, d.definition FROM en_senses s JOIN en_synsets d ON d.synset_id = s.synset_id "
            "WHERE s.lemma = ? AND s.pos = ? ORDER BY s.rank", (lemma, pos)
        ).fetchall()
        for synset_id, definition in rows[:MAX_SENSES]:
            members = [m for (m,) in self.db.execute(
                "SELECT lemma FROM en_synset_members WHERE synset_id = ? ORDER BY rank", (synset_id,)
            ).fetchall() if m.lower() != lemma.lower() and (lemma, m) not in hidden]
            senses.append((synset_id, definition, members[:MAX_SYNONYMS]))
        translations = self.db.execute(
            "SELECT sv, comment FROM en_sv WHERE en_lemma = ? AND pos = ? ORDER BY rank", (normalize(lemma), pos)
        ).fetchall()
        seen = set()
        unique = []
        for sv, comment in translations:
            if sv not in seen:
                seen.add(sv)
                unique.append((sv, comment))
        return {"lemma": lemma, "pos": pos, "pos_name": EN_POS_NAMES.get(pos, ""),
                "senses": senses, "translations": unique[:MAX_TRANSLATIONS]}

    def lookup_en(self, word, hidden=frozenset(), preferred_pos=None):
        key = normalize(word)
        if not key:
            return None
        candidates = self.en_candidates(key)
        if not candidates:
            return None
        entries = [self.en_entry(lemma, pos, hidden) for lemma, pos in candidates]
        entries = [e for e in entries if e["senses"] or e["translations"]] or entries

        def order(entry):
            return (entry["pos"] != preferred_pos if preferred_pos else False,
                    not entry["senses"] and not entry["translations"],
                    normalize(entry["lemma"]) != key,
                    EN_POS_ORDER.index(entry["pos"]) if entry["pos"] in EN_POS_ORDER else 99,
                    entry["lemma"])
        entries.sort(key=order)
        return {"language": "en", "word": word, "key": key, "compound": None, "entries": entries}

    def has(self, word):
        """Vilka språk ordet finns i: (svenska, engelska)."""
        key = normalize(word)
        sv = bool(self.sv_lemmas(key))
        en = bool(self.en_candidates(key))
        return sv, en


def format_result(result):
    if result is None:
        return "  (finns inte)"
    lines = []
    if result.get("compound"):
        head, tail = result["compound"]
        lines.append(f"  sammansatt: {head} + {tail}")
    for entry in result["entries"]:
        lines.append(f"  {entry['lemma']}, {entry['pos_name'] or entry['pos']}")
        if result["language"] == "sv":
            if not entry["senses"]:
                lines.append("      (inga synonymer)")
            for number, (sense_id, synonyms) in enumerate(entry["senses"], 1):
                text = ", ".join(f"{word} {score:g}" for word, score in synonyms)
                lines.append(f"      {number}. {text}   [{sense_id}]")
        else:
            if entry["translations"]:
                text = ", ".join(sv + (f" ({comment})" if comment else "") for sv, comment in entry["translations"])
                lines.append(f"      svenska: {text}")
            for number, (synset_id, definition, members) in enumerate(entry["senses"], 1):
                synonyms = ", ".join(members) if members else "(inga synonymer)"
                lines.append(f"      {number}. {synonyms}: {definition}")
    return "\n".join(lines)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    dictionary = Dictionary(sys.argv[1])
    for word in sys.argv[2:]:
        sv, en = dictionary.has(word)
        print(f"{word}  (svenska: {'ja' if sv else 'nej'}, engelska: {'ja' if en else 'nej'})")
        if sv or not en:
            print(format_result(dictionary.lookup_sv(word)))
        if en:
            print(format_result(dictionary.lookup_en(word)))
