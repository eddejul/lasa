"""Testrapporten: appens svar för varje ord i testwords.txt, så att de kan jämföras med svenska.se."""

import datetime
import sqlite3
import time

from lookup import Dictionary, format_result, normalize


def read_testwords(path):
    words = []
    language = "sv"
    with open(path, encoding="utf-8") as file:
        for line in file:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line in ("[sv]", "[en]"):
                language = line[1:3]
                continue
            words.append((language, line))
    return words


def wiktionary_lines(db, language, result):
    """O10: uttal och ursprung (svenska) eller fler översättningar (engelska) för första uppslagsordet,
    som ordkortet visar dem. Hör inte till uppslaget, så lookup.py och lookup.js är oförändrade."""
    if not result or not result["entries"]:
        return []
    entry = result["entries"][0]
    try:
        if language == "sv":
            row = db.execute("SELECT ipa, etymology FROM sv_wiktionary WHERE lemma = ?", (entry["lemma"],)).fetchone()
            if row and (row[0] or row[1]):
                return [f"      WIKTIONARY: {row[0] or '(inget uttal)'} | {row[1] or '(inget ursprung)'}"]
        else:
            words = [row[0] for row in db.execute(
                "SELECT sv FROM en_sv_wiktionary WHERE en_lemma = ? AND pos = ? ORDER BY rank",
                (normalize(entry["lemma"]), entry["pos"]))]
            if words:
                return ["      WIKTIONARY, FLER: " + ", ".join(words)]
    except sqlite3.OperationalError:
        return []
    return []


def write_report(db_path, testwords_path, report_path, stats, checksums):
    dictionary = Dictionary(db_path)
    wiktionary = sqlite3.connect(db_path)
    words = read_testwords(testwords_path)
    lines = [
        "Läsa, testrapport för ordboken",
        f"Byggd {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC",
        "",
        "Statistik:",
    ]
    lines += [f"  {key}: {value}" for key, value in sorted(stats.items())]
    lines += ["", "Källornas sha256:"]
    lines += [f"  {name}: {digest}" for name, digest in sorted(checksums.items())]
    lines += [""]

    summary = {"sv": [0, 0, 0], "en": [0, 0, 0]}  # hittade, med synonymer, med översättning
    timings = []
    body = []
    for language, word in words:
        started = time.perf_counter()
        if language == "sv":
            result = dictionary.lookup_sv(word)
        else:
            result = dictionary.lookup_en(word)
        timings.append((time.perf_counter() - started) * 1000)
        sv, en = dictionary.has(word)
        other = en if language == "sv" else sv
        note = "  (finns också i den andra språkets tabell)" if other else ""
        body.append(f"[{language}] {word}{note}")
        body.append(format_result(result))
        body.extend(wiktionary_lines(wiktionary, language, result))
        if result:
            counts = summary[language]
            counts[0] += 1
            if any(entry["senses"] for entry in result["entries"]):
                counts[1] += 1
            if any(entry.get("translations") for entry in result["entries"]):
                counts[2] += 1

    for language, name in (("sv", "Svenska"), ("en", "Engelska")):
        total = sum(1 for lang, _ in words if lang == language)
        found, with_synonyms, with_translations = summary[language]
        text = f"{name}: {found} av {total} hittade, {with_synonyms} med synonymer"
        if language == "en":
            text += f", {with_translations} med svensk översättning"
        lines.append(text)
    if timings:
        timings.sort()
        lines.append(f"Uppslag på byggservern: median {timings[len(timings) // 2]:.1f} ms, "
                     f"längst {timings[-1]:.1f} ms")
    lines += ["", "Ord för ord:", ""] + body
    with open(report_path, "w", encoding="utf-8") as file:
        file.write("\n".join(lines) + "\n")
