"""Uppslag i ordboksdatabasen, på samma sätt som appen gör (App/Dictionary/WordDictionary.swift).

Ändras logiken här ska den ändras i appen också, och tvärtom. Rapporten (report.py) använder
den här filen, så testlistan visar exakt vad appen visar.

  python tools/dictionary/lookup.py out/lasa-ordbok.sqlite sprang went exceedingly
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
MAX_TRANSLATIONS = 6
# Så många synonymer visas direkt. Resten finns bakom Visa fler.
TOP_SYNONYMS = 5
# Ord under den här vanligheten (Zipf, wordfreq) märks som ovanliga och visas sist.
RARE_ZIPF = 2.0
# Hur mycket vanligheten väger mot Synlex-betyget när svenska synonymer sorteras.
SV_FREQ_WEIGHT = 0.5
# Översättningar ur Folkets svensk-engelska del (omvända) har rank från och med det här.
REVERSED_RANK = 500
# Engelska ord utan egen översättning lånar den från en synonym i någon av de första betydelserna.
BORROW_SENSES = 3


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


def _sv_synonym_key(synonym):
    word, score, freq = synonym
    return (-(score + SV_FREQ_WEIGHT * freq), word)


def _en_synonym_key(synonym):
    word, _score, freq = synonym
    return (-freq, word)


def _ordered(synonyms, key):
    """Vanliga först (sorterade), ovanliga sist."""
    common = sorted((s for s in synonyms if s[2] >= RARE_ZIPF), key=key)
    rare = sorted((s for s in synonyms if s[2] < RARE_ZIPF), key=key)
    return common + rare


class Dictionary:

    def __init__(self, path):
        self.db = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)

    # MARK: Svenska

    def sv_lemmas(self, key):
        return self.db.execute("SELECT lemma, pos FROM sv_forms WHERE form = ?", (key,)).fetchall()

    def sv_entry(self, lemma, pos, hidden=frozenset()):
        synonyms = {}
        for sense_id, synonym, score, freq in self.db.execute(
                "SELECT sense_id, synonym, score, freq FROM sv_synonyms WHERE lemma = ? AND pos = ?", (lemma, pos)):
            if (lemma, synonym) in hidden:
                continue
            synonyms.setdefault(sense_id, []).append((synonym, score, freq))
        definitions = {}
        loose = []  # definitioner utan känd betydelse
        for sense_id, definition in self.db.execute(
                "SELECT sense_id, definition FROM sv_definitions WHERE lemma = ? AND pos = ? ORDER BY rank",
                (lemma, pos)):
            if sense_id and sense_id not in definitions:
                definitions[sense_id] = definition
            elif not sense_id and definition not in loose:
                loose.append(definition)

        # Betydelser med nummer först (synonymer och definition ihop), sedan lösa definitioner,
        # sist synonymer utan känd betydelse.
        numbered = sorted({s for s in list(synonyms) + list(definitions) if s}, key=_sense_number)
        senses = []
        for sense_id in numbered:
            ordered = _ordered(synonyms.get(sense_id, []), _sv_synonym_key)
            senses.append({"id": sense_id, "definition": definitions.get(sense_id),
                           "synonyms": ordered[:MAX_SYNONYMS]})
        for index, definition in enumerate(loose):
            # En lös definition på ett ord med en enda betydelse hör till den.
            if len(senses) == 1 and not senses[0]["definition"]:
                senses[0]["definition"] = definition
                continue
            senses.append({"id": f"definition..{index}", "definition": definition, "synonyms": []})
        if synonyms.get(""):
            senses.append({"id": "", "definition": None,
                           "synonyms": _ordered(synonyms[""], _sv_synonym_key)[:MAX_SYNONYMS]})
        return {"lemma": lemma, "pos": pos, "pos_name": SV_POS_NAMES.get(pos, ""),
                "senses": senses[:MAX_SENSES], "translations": [], "via": None}

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
            # Ord med innehåll först, sedan grundformen själv, sedan flest synonymer (ett mått på
            # hur vanlig ordklassen är), sedan ordklassernas fasta ordning.
            return (not entry["senses"],
                    normalize(entry["lemma"]) != key,
                    -sum(len(sense["synonyms"]) for sense in entry["senses"]),
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

    def en_forms(self, key):
        return self.db.execute("SELECT lemma, pos FROM en_forms WHERE form = ?", (key,)).fetchall()

    def en_candidates(self, key):
        """(grundform, ordklass) för en engelsk form: först formtabellen, sedan reglerna."""
        found = []

        def add(rows, pos=None):
            for lemma, row_pos in rows:
                if pos and row_pos != pos:
                    continue
                if (lemma, row_pos) not in found:
                    found.append((lemma, row_pos))

        add(self.en_forms(key))
        base_key = key[:-2] if key.endswith("'s") else key
        if base_key != key:
            add(self.en_forms(base_key))
        for suffix, replacement, pos in EN_RULES:
            if not base_key.endswith(suffix) or len(base_key) <= len(suffix) + 1:
                continue
            stem = base_key[: -len(suffix)] + replacement
            rows = self.en_forms(stem)
            if not [r for r in rows if r[1] == pos] and not replacement \
                    and len(stem) > 2 and stem[-1] == stem[-2] and stem[-1] not in "aeiouy":
                # stopped, stopping, bigger: dubbelteckning. Bara om formen utan den inte redan finns (filled).
                rows = self.en_forms(stem[:-1])
            add(rows, pos)
        return found

    def en_translations(self, lemma, pos):
        """Folkets egna översättningar först. Finns inga används de omvända (svensk-engelska delen)."""
        rows = self.db.execute(
            "SELECT sv, comment, rank FROM en_sv WHERE en_lemma = ? AND pos = ? ORDER BY rank", (normalize(lemma), pos)
        ).fetchall()
        direct = [(sv, comment) for sv, comment, rank in rows if rank < REVERSED_RANK]
        chosen = direct or [(sv, comment) for sv, comment, rank in rows if rank >= REVERSED_RANK]
        seen = set()
        unique = []
        for sv, comment in chosen:
            if sv not in seen:
                seen.add(sv)
                unique.append((sv, comment))
        return unique[:MAX_TRANSLATIONS]

    def en_entry(self, lemma, pos, hidden=frozenset()):
        senses = []
        rows = self.db.execute(
            "SELECT s.synset_id, d.definition FROM en_senses s JOIN en_synsets d ON d.synset_id = s.synset_id "
            "WHERE s.lemma = ? AND s.pos = ? ORDER BY s.rank", (lemma, pos)
        ).fetchall()
        for synset_id, definition in rows[:MAX_SENSES]:
            members = [(m, None, f) for m, f in self.db.execute(
                "SELECT lemma, freq FROM en_synset_members WHERE synset_id = ? ORDER BY rank", (synset_id,)
            ).fetchall() if m.lower() != lemma.lower() and (lemma, m) not in hidden]
            senses.append({"id": synset_id, "definition": definition,
                           "synonyms": _ordered(members, _en_synonym_key)[:MAX_SYNONYMS]})

        translations = self.en_translations(lemma, pos)
        via = None
        if not translations:
            # Lånad översättning: exceedingly saknas i Folkets lexikon, men extremely (samma betydelse) finns.
            for sense in senses[:BORROW_SENSES]:
                for member, _score, _freq in sense["synonyms"]:
                    borrowed = self.en_translations(member, pos)
                    if borrowed:
                        translations, via = borrowed[:4], member
                        break
                if via:
                    break
        return {"lemma": lemma, "pos": pos, "pos_name": EN_POS_NAMES.get(pos, ""),
                "senses": senses, "translations": translations, "via": via}

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


def _synonym_text(synonyms):
    shown = [word + (" (ovanligt)" if freq < RARE_ZIPF else "") for word, _score, freq in synonyms[:TOP_SYNONYMS]]
    text = ", ".join(shown)
    if len(synonyms) > TOP_SYNONYMS:
        text += f" (+{len(synonyms) - TOP_SYNONYMS} fler)"
    return text


def format_result(result):
    """Rapportens text, i samma ordning som rutan i appen."""
    if result is None:
        return "  (finns inte)"
    lines = []
    if result.get("compound"):
        head, tail = result["compound"]
        lines.append(f"  sammansatt: {head} + {tail}")
    for entry in result["entries"]:
        lines.append(f"  {entry['lemma']}, {entry['pos_name'] or entry['pos']}")
        if result["language"] == "en":
            if entry["translations"]:
                text = ", ".join(sv + (f" ({comment})" if comment else "") for sv, comment in entry["translations"])
                if entry["via"]:
                    text += f"   [som {entry['via']}]"
                lines.append(f"      PÅ SVENSKA: {text}")
            else:
                lines.append("      PÅ SVENSKA: (ingen översättning)")
        if not entry["senses"]:
            lines.append("      (inga betydelser eller synonymer)")
        for number, sense in enumerate(entry["senses"], 1):
            parts = []
            if sense["definition"]:
                parts.append(sense["definition"])
            if sense["synonyms"]:
                parts.append("liknande: " + _synonym_text(sense["synonyms"]))
            lines.append(f"      {number}. " + " | ".join(parts) + (f"   [{sense['id']}]" if sense["id"] else ""))
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
