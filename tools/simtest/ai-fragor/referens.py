"""Referensen för AI-frågornas kontroll (docs/AI-FRAGOR.md, avsnittet Kontrollen).

Skriptet bygger fixtur-1.json: ett påhittat kapitel, ett modellsvar med en fråga för varje regel och det
väntade resultatet (vilka frågor som behålls, med id, och varför de andra slängs). iPadens XCTest och
Windows-appens node-test ska ge exakt samma resultat. Ändras en regel: ändra här, kör om skriptet och rätta
båda apparna i samma commit.

    python tools/simtest/ai-fragor/referens.py
"""

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

TYPER = [
    "huvudpoang", "egna_ord", "svar_mening", "vems_rost", "varfor", "uppgift", "koppling", "skillnad",
    "tillampa", "falla", "belagg", "kritisk", "anvand", "sammanfatta", "annan_bok", "verkligheten",
    "foljder", "gransen", "overforing", "debatt", "syntes",
]
OPPNA_TYPER = {"kritisk", "anvand", "annan_bok", "verkligheten", "foljder", "gransen", "overforing", "debatt",
               "syntes"}
UTAN_KALLA = {"sammanfatta", "syntes"}
NAR = ["fore", "efter", "slut"]
AVSTAND = 400

LOSA = {}
for tecken in "‘’‚‛′´`":
    LOSA[tecken] = "'"
for tecken in "“”„‟″«»":
    LOSA[tecken] = '"'
for tecken in "–—‒―−":
    LOSA[tecken] = "-"


def vik(text):
    """Som FoldedText: små bokstäver, ett mellanslag mellan orden, mjuka och radslutets avstavningar bort.
    Ger den vikta texten och en karta tillbaka till originalets index."""
    ut, karta = [], []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "­":
            i += 1
            continue
        if c in " \t \n\r  \u000B\u000C":
            if ut and ut[-1] != " ":
                ut.append(" ")
                karta.append(i)
            i += 1
            continue
        if c in "-‐‑" and ut and ut[-1] != " ":
            j, bryt = i + 1, False
            while j < n and text[j] in " \t \n\r  \u000B\u000C":
                if text[j] in "\n\r  ":
                    bryt = True
                j += 1
            if bryt and j < n and text[j].islower():
                i = j
                continue
        ut.append(c.lower())
        karta.append(i)
        i += 1
    return "".join(ut), karta


def fraga_vikt(text):
    return vik(text)[0].strip(" ")


def hitta(citat, kapitel):
    """Slutet (index i originalet, exklusive) för citatets första träff, eller None. Först strikt, sedan löst
    (typografiska citattecken och streck som raka), alltid tecken för tecken så att indexen stämmer."""
    for losa in (False, True):
        k, c = kapitel, citat
        if losa:
            k = "".join(LOSA.get(t, t) for t in k)
            c = "".join(LOSA.get(t, t) for t in c)
        vk, karta = vik(k)
        q = fraga_vikt(c)
        if len(q) < 2:
            return None
        pos = vk.find(q)
        if pos >= 0:
            return karta[pos + len(q) - 1] + 1
    return None


def ord_lista(text):
    return re.findall(r"[^\W_]+", vik(text)[0])


def kopierad(fraga, kapitel_ord, n=6):
    ord_f = ord_lista(fraga)
    kap = set(tuple(kapitel_ord[i:i + n]) for i in range(len(kapitel_ord) - n + 1))
    return any(tuple(ord_f[i:i + n]) in kap for i in range(len(ord_f) - n + 1))


def fnv(text):
    h = 0xcbf29ce484222325
    for b in text.encode("utf-8"):
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def bas36(tal):
    tecken = "0123456789abcdefghijklmnopqrstuvwxyz"
    if tal == 0:
        return "0"
    ut = ""
    while tal:
        tal, r = divmod(tal, 36)
        ut = tecken[r] + ut
    return ut


def fraga_id(bok_id, nyckel, del_nr, nar, fraga):
    return "ai" + bas36(fnv(f"{bok_id}|{nyckel}|{del_nr}|{nar}|{fraga}"))


def antal(tecken, sista=False):
    efter = min(max(round(tecken / 3500), 2), 10)
    fore = 2 if tecken >= 8000 else 1
    kopplingar = 2 if tecken >= 8000 else 1
    return {"efter": efter, "fore": fore, "kopplingar": kopplingar, "slut": 1 + kopplingar + (1 if sista else 0)}


def antal_text(tal):
    return "1 fråga" if tal == 1 else f"{tal} frågor"


def bygg_prompt(bok, kapitel, tidigare, andra, tal):
    """Frågan till modellen, tecken för tecken som i docs/AI-FRAGOR.md. `tal` är antal() för delen, där
    fore är 0 i en senare del och slut 0 i en tidigare del."""
    forfattare = f", av {bok['forfattare']}" if bok.get("forfattare") else ""
    delrad = f" (del {kapitel['del']} av {kapitel['delar']})" if kapitel["delar"] > 1 else ""
    tidigare_rader = "\n".join(f"- {t['rubrik']}: {t['sammanfattning']}" for t in tidigare[-12:]) or "Inga."
    andra_rader = []
    for b in andra[:5]:
        rad = f"- {b['titel']}: {b['sammanfattning']}"
        if b.get("begrepp"):
            rad += " Begrepp: " + ", ".join(b["begrepp"][:8]) + "."
        andra_rader.append(rad)
    andra_text = "\n".join(andra_rader) or "Inga."
    if tal["fore"] > 0:
        rad_b = (f"b) {antal_text(tal['fore'])} med \"nar\": \"fore\": det viktigaste läsaren ska ha i huvudet "
                 "medan hen läser. \"plats\" lämnas tom.")
    else:
        rad_b = "b) Inga frågor med \"nar\": \"fore\"."
    if tal["slut"] > 0:
        syntes = (" Det här är bokens sista kapitel: lägg till en fråga av typen syntes om hur bokens viktigaste "
                  "idéer hänger ihop." if kapitel.get("sista") else "")
        rad_c = (f"c) {antal_text(tal['slut'])} med \"nar\": \"slut\": en av typen sammanfatta, och "
                 f"{antal_text(tal['kopplingar'])} som kräver större kopplingar än texten, av typerna annan_bok, "
                 "verkligheten, foljder, gransen, overforing eller debatt. annan_bok och debatt mellan böcker får "
                 "bara gälla böckerna i listan ovan, med titeln exakt som där i \"bok\"." + syntes
                 + " \"plats\" lämnas tom.")
    else:
        rad_c = "c) Inga frågor med \"nar\": \"slut\"."
    return "\n".join([
        "Du gör frågor som hjälper en läsare att förstå och minnas en bok. Läsaren svarar ur minnet, med egna "
        "ord, efter att ha läst avsnittet.",
        "",
        f"Bok: {bok['titel']}{forfattare}",
        f"Kapitel: {kapitel['rubrik']}{delrad}",
        "",
        "Tidigare kapitel i boken:",
        tidigare_rader,
        "",
        "Andra böcker som läsaren har läst:",
        andra_text,
        "",
        "Gör så här.",
        "1. \"sammanfattning\": kapitlets huvudpoäng i högst tre meningar.",
        "2. \"begrepp\": högst åtta viktiga begrepp eller namn ur kapitlet, skrivna som i texten.",
        "3. \"fragor\":",
        f"a) {antal_text(tal['efter'])} med \"nar\": \"efter\", spridda jämnt över hela texten. Varje fråga "
        "gäller ett avsnitt. \"plats\" är 4 till 10 ord som står ordagrant i avsnittets sista mening, så att "
        "frågan visas när avsnittet är läst.",
        rad_b,
        rad_c,
        "4. Välj typ efter vad avsnittet bär: ett begrepp ger egna_ord eller skillnad, ett argument varfor eller "
        "belagg, en återgiven åsikt vems_rost, ett svårt ställe svar_mening. Blanda typerna.",
        "5. Skriv frågan med andra ord än boken. Upprepa aldrig fem ord i rad ur texten.",
        "6. \"svar\": två eller tre korta kärnpunkter med egna ord, som ett bra svar innehåller. För en öppen "
        "fråga (\"oppen\": true): vad boken säger som läsaren kan ställa sitt svar mot.",
        "7. \"kalla\": 5 till 30 ord som står ordagrant i texten, där svaret står. Kopiera tecken för tecken, "
        "utan att ändra, korta eller översätta. Lämna \"kalla\" tom bara när svaret inte står i texten.",
        "8. Skriv frågor, svar och sammanfattning på svenska, även när boken är på ett annat språk. \"plats\", "
        "\"kalla\" och \"begrepp\" står på bokens språk, precis som i texten.",
        "9. Fråga inte efter sidnummer, årtal, namn eller detaljer som inte hjälper förståelsen.",
        "",
        "Kapitlets text:",
        "<text>",
        kapitel["text"],
        "</text>",
    ])


def bygg_jamfor(fraga, mitt_svar):
    """Frågan till modellen när läsarens svar jämförs (Jämför). Kapitlets text skickas aldrig med."""
    punkter = "\n".join(f"- {s}" for s in fraga["svar"]) or "- (inga punkter)"
    kalla = f"\"{fraga['kalla']}\"" if fraga["kalla"] else "Inget citat."
    if fraga["oppen"]:
        slut = ("Frågan är öppen och har inget rätt svar. Skriv i \"kommentar\" om resonemanget håller och vad "
                "boken säger, och lämna \"fel\" tom om inget strider mot boken. Säg tydligt när något i "
                "kommentaren kommer från dig och inte från boken.")
    else:
        slut = ("Lista i \"med\" det läsaren fick med, i \"saknas\" det som saknas och i \"fel\" det som strider "
                "mot boken. \"kommentar\" är en mening.")
    return "\n".join([
        "Du bedömer en läsares svar på en fråga om en bok. Bedöm innehållet, inte orden: samma sak med andra "
        "ord räknas som rätt. Var vänlig och konkret, och skriv på svenska.",
        "",
        f"Fråga: {fraga['fraga']}",
        "Ett bra svar innehåller:",
        punkter,
        f"Ur boken: {kalla}",
        f"Läsarens svar: {mitt_svar.strip()}",
        "",
        slut,
    ])


SCHEMA_FRAGOR = {
    "type": "object",
    "properties": {
        "sammanfattning": {"type": "string"},
        "begrepp": {"type": "array", "items": {"type": "string"}},
        "fragor": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "typ": {"type": "string", "enum": TYPER},
                "nar": {"type": "string", "enum": NAR},
                "fraga": {"type": "string"},
                "svar": {"type": "array", "items": {"type": "string"}},
                "oppen": {"type": "boolean"},
                "plats": {"type": "string"},
                "kalla": {"type": "string"},
                "bok": {"type": "string"},
            },
            "required": ["typ", "nar", "fraga", "svar", "oppen", "plats", "kalla"],
        }},
    },
    "required": ["sammanfattning", "begrepp", "fragor"],
}

SCHEMA_JAMFOR = {
    "type": "object",
    "properties": {
        "med": {"type": "array", "items": {"type": "string"}},
        "saknas": {"type": "array", "items": {"type": "string"}},
        "fel": {"type": "array", "items": {"type": "string"}},
        "omdome": {"type": "string", "enum": ["bra", "delvis", "saknas_mycket"]},
        "kommentar": {"type": "string"},
    },
    "required": ["med", "saknas", "fel", "omdome", "kommentar"],
}


def kontrollera(svar, kapitel, bok_id, nyckel, del_nr, andra_titlar, tak):
    """Reglerna i docs/AI-FRAGOR.md. Ger (behållna, slängda)."""
    text = kapitel
    kapitel_ord = ord_lista(text)
    titlar = {fraga_vikt(t) for t in andra_titlar}
    kvar, slangda = [], []
    for nr, f in enumerate(svar.get("fragor", [])):
        typ = str(f.get("typ", "")).strip()
        nar = str(f.get("nar", "")).strip()
        fraga = str(f.get("fraga", "")).strip()
        svar_rader = [str(s).strip() for s in f.get("svar", []) if str(s).strip()]
        oppen = bool(f.get("oppen")) or typ in OPPNA_TYPER
        plats = str(f.get("plats", "")).strip()
        kalla = str(f.get("kalla", "")).strip()
        bok = str(f.get("bok", "")).strip()
        def slang(orsak):
            slangda.append({"nr": nr, "fraga": fraga, "orsak": orsak})
        if typ not in TYPER or nar not in NAR:
            slang("typ"); continue
        if len(fraga) < 8:
            slang("fraga"); continue
        if not svar_rader and not oppen:
            slang("svar"); continue
        position = None
        if nar == "efter":
            position = hitta(plats, text) if plats else None
            if position is None:
                slang("plats"); continue
        behover_kalla = not oppen and typ not in UTAN_KALLA
        if kalla:
            if hitta(kalla, text) is None:
                if behover_kalla:
                    slang("kalla"); continue
                kalla = ""
        elif behover_kalla:
            slang("kalla"); continue
        if kopierad(fraga, kapitel_ord):
            slang("kopierad"); continue
        if typ == "annan_bok" or (typ == "debatt" and bok):
            if fraga_vikt(bok) not in titlar:
                slang("bok"); continue
        kvar.append({"nr": nr, "typ": typ, "nar": nar, "fraga": fraga, "svar": svar_rader, "oppen": oppen,
                     "plats": plats if nar == "efter" else "", "kalla": kalla, "bok": bok, "position": position})
    # Frågorna i texten i textens ordning, med avstånd.
    efter = sorted([f for f in kvar if f["nar"] == "efter"], key=lambda f: (f["position"], f["nr"]))
    behallna_efter, senaste = [], None
    for f in efter:
        if senaste is not None and f["position"] - senaste < AVSTAND:
            slangda.append({"nr": f["nr"], "fraga": f["fraga"], "orsak": "avstand"})
            continue
        behallna_efter.append(f)
        senaste = f["position"]
    ordning = ([f for f in kvar if f["nar"] == "fore"] + behallna_efter + [f for f in kvar if f["nar"] == "slut"])
    raknat = {"fore": 0, "efter": 0, "slut": 0}
    behallna = []
    for f in ordning:
        if raknat[f["nar"]] >= tak[f["nar"]]:
            slangda.append({"nr": f["nr"], "fraga": f["fraga"], "orsak": "tak"})
            continue
        raknat[f["nar"]] += 1
        f["id"] = fraga_id(bok_id, nyckel, del_nr, f["nar"], f["fraga"])
        behallna.append(f)
    slangda.sort(key=lambda s: s["nr"])
    return behallna, slangda


KAPITEL = "\n\n".join([
    "Den som vill förstå en vana måste först se vad den ger. En vana är sällan ett tecken på svag vilja. "
    "Den är ett svar på ett behov som återkommer, och hjärnan lär sig snabbt vilka handlingar som brukar "
    "löna sig. Varje gång en handling följs av en belöning blir det lite lättare att göra samma sak nästa "
    "gång.",
    "Forskare brukar beskriva vanan som en slinga med tre delar. Först kommer en signal, till exempel en tid "
    "på dygnet, en plats eller en känsla. Sedan kommer själva beteendet. Till sist kommer belöningen, som kan "
    "vara allt från socker till lättnad eller sällskap. När slingan har upprepats tillräckligt många gånger "
    "börjar signalen ensam väcka ett sug efter belöningen.",
    "Därför fungerar det dåligt att bara bestämma sig för att sluta. Signalen finns kvar och suget kommer "
    "tillbaka. Det som fungerar bättre är att behålla signalen och belöningen men ”byta ut "
    "beteendet” i mitten. Den som äter godis av tristess på eftermiddagen kan i stället ta en kort "
    "promenad, som också bryter tristessen.",
    "Alla håller inte med om den här bilden. Kritiker menar att slingan förenklar för mycket, eftersom många "
    "vanor hänger ihop med miljön och inte bara med den enskilda människan. Om godiset ligger framme på "
    "kontoret spelar viljan mindre roll än man tror. Författaren medger att miljön betyder mycket, men "
    "hävdar att slingan ändå är det bästa verktyget för den som vill förändra sitt eget beteende.",
    "Det viktigaste är kanske att se vanor som något man kan undersöka. Den som skriver ner när suget kommer, "
    "var hen befinner sig och vad som händer efteråt hittar ofta mönster som tidigare var osynliga. Först då "
    "går det att välja ett nytt beteende som ger samma belöning.",
])

ANDRA = [
    {"titel": "Atomvanor", "sammanfattning": "Små vanor som upprepas ger stora förändringar över tid.",
     "begrepp": ["identitet", "miljödesign", "vanestapling"]},
    {"titel": "Tänka, snabbt och långsamt", "sammanfattning": "Två system för tänkande, ett snabbt och ett "
     "långsamt, och de fel det snabba gör.", "begrepp": ["system 1", "system 2", "förankring"]},
]


def q(typ, nar, fraga, svar, oppen=False, plats="", kalla="", bok=""):
    return {"typ": typ, "nar": nar, "fraga": fraga, "svar": svar, "oppen": oppen, "plats": plats,
            "kalla": kalla, "bok": bok}


SVAR = {
    "sammanfattning": "Kapitlet beskriver vanan som en slinga av signal, beteende och belöning, och säger att "
                      "man ändrar en vana genom att byta beteendet men behålla signal och belöning.",
    "begrepp": ["signal", "beteende", "belöning", "slinga", "miljön"],
    "fragor": [
        # 0 behålls: allt hittas.
        q("varfor", "efter", "Varför är en vana enligt texten inte ett tecken på dålig karaktär?",
          ["Vanan svarar på ett behov som kommer tillbaka.", "Hjärnan lär sig vilka handlingar som brukar ge något."],
          plats="lättare att göra samma sak nästa gång",
          kalla="Den är ett svar på ett behov som återkommer"),
        # 1 slängs: platsen står inte i texten.
        q("huvudpoang", "efter", "Vad är avsnittets viktigaste poäng om vanor?", ["Vanor kan ändras."],
          plats="slingan med fyra delar och en signal", kalla="En vana är sällan ett tecken på svag vilja"),
        # 2 slängs: källan står inte i texten och frågan har ett rätt svar.
        q("egna_ord", "efter", "Förklara med egna ord hur en vana blir automatisk.", ["Signalen väcker suget."],
          plats="väcka ett sug efter belöningen", kalla="Vanan består alltid av exakt tre steg"),
        # 3 slängs: frågan upprepar sex ord i rad ur texten.
        q("uppgift", "efter", "Vad menas med att signalen finns kvar och suget kommer tillbaka, och vad gör man då?",
          ["Man byter beteendet."], plats="som också bryter tristessen",
          kalla="Signalen finns kvar och suget kommer tillbaka"),
        # 4 slängs: för nära fråga 0 i texten.
        q("skillnad", "efter", "Vilka delar består vanans kedja av, och i vilken ordning kommer de?",
          ["Signal, beteende, belöning."], plats="en slinga med tre delar", kalla="Först kommer en signal"),
        # 5 behålls: platsen har andra stora bokstäver och en radbrytning.
        q("vems_rost", "efter", "Vem är det som invänder mot bilden av vanan som en slinga, och vad pekar invändningen på?",
          ["Kritikerna pekar på att omgivningen styr mycket.", "Exemplet är godis som ligger framme på jobbet."],
          plats="MILJÖN och inte bara med\nden enskilda människan",
          kalla="Om godiset ligger framme på kontoret spelar viljan mindre roll än man tror"),
        # 6 behålls: källan har raka citattecken, texten typografiska.
        q("huvudpoang", "fore", "Vad är det enda i vanans kedja som går att byta, enligt författaren?",
          ["Beteendet i mitten.", "Signalen och belöningen får vara kvar."],
          kalla="men \"byta ut beteendet\" i mitten"),
        # 7 behålls: en annan bok som finns i listan.
        q("annan_bok", "slut", "Hur skiljer sig synen på miljön här från den i Atomvanor?",
          ["Kapitlet säger att miljön betyder mycket men att slingan är viktigast."], oppen=True, bok="Atomvanor"),
        # 8 slängs: boken finns inte i listan.
        q("annan_bok", "slut", "Vad skulle Kraften i vanor säga om slingan?", ["Okänt."], oppen=True,
          bok="Kraften i vanor"),
        # 9 behålls utan källa: öppen fråga vars källa inte står i texten.
        q("kritisk", "slut", "Var tycker du att slingmodellen är svagast, och vad skulle en kritiker säga?",
          ["Boken medger att miljön betyder mycket."], oppen=True, kalla="Slingan är bevisad i tusentals studier"),
        # 10 slängs: okänd typ.
        q("quiz", "efter", "Vilket år skrevs boken?", ["Okänt."], plats="samma belöning"),
        # 11 slängs: inget svar på en fråga som har ett rätt svar.
        q("skillnad", "efter", "Vad skiljer ett nytt beteende från ett gammalt?", [], plats="ger samma belöning"),
        # 12 behålls: en sammanfattning behöver ingen källa.
        q("sammanfatta", "slut", "Sammanfatta kapitlet i två meningar: vad är en vana och hur ändrar man den?",
          ["En vana är signal, beteende och belöning.", "Man byter beteendet och behåller resten."]),
    ],
}


def main():
    bok_id = "11111111-2222-3333-4444-555555555555"
    nyckel, del_nr = "k3", 1
    tal = antal(len(KAPITEL))
    tak = {"fore": 2, "efter": tal["efter"] + 2, "slut": 4}
    behallna, slangda = kontrollera(SVAR, KAPITEL, bok_id, nyckel, del_nr, [b["titel"] for b in ANDRA], tak)
    bok = {"id": bok_id, "titel": "Vanans väg", "forfattare": "Testförfattare"}
    kapitel = {"nyckel": nyckel, "rubrik": "Slingan", "del": del_nr, "delar": 1, "text": KAPITEL, "sista": False}
    tidigare = [{"rubrik": "Inledning", "sammanfattning": "Boken handlar om hur vanor uppstår och kan ändras."}]
    jamfor_fraga = next(f for f in behallna if f["nr"] == 0)
    mitt_svar = "  För att vanan svarar på något man behöver, och hjärnan lär sig vad som lönar sig.\n"
    oppen_fraga = next(f for f in behallna if f["nr"] == 9)
    fixtur = {
        "prompt": bygg_prompt(bok, kapitel, tidigare, ANDRA, tal),
        "tidigare": tidigare,
        "schemaFragor": SCHEMA_FRAGOR,
        "schemaJamfor": SCHEMA_JAMFOR,
        "jamfor": [
            {"nr": 0, "mittSvar": mitt_svar, "prompt": bygg_jamfor(jamfor_fraga, mitt_svar)},
            {"nr": 9, "mittSvar": "Den missar miljön.", "prompt": bygg_jamfor(oppen_fraga, "Den missar miljön.")},
        ],
        "om": "Skapad av referens.py. Påhittat kapitel och modellsvar, en fråga per regel i docs/AI-FRAGOR.md. "
              "Ändra inte för hand.",
        "bok": bok,
        "kapitel": kapitel,
        "andraBocker": ANDRA,
        "antal": tal,
        "tak": tak,
        "svar": SVAR,
        "vantat": {
            "behalls": [{k: f[k] for k in ("id", "nr", "typ", "nar", "fraga", "kalla", "oppen", "position")}
                        for f in behallna],
            "slangs": slangda,
        },
    }
    ut = HERE / "fixtur-1.json"
    ut.write_text(json.dumps(fixtur, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print(f"{len(KAPITEL)} tecken, antal {tal}, tak {tak}")
    for f in behallna:
        print("behålls", f["nr"], f["nar"], f["typ"], f["id"], f["position"], repr(f["kalla"][:30]))
    for s in slangda:
        print("slängs ", s["nr"], s["orsak"])
    print("skrev", ut)


if __name__ == "__main__":
    main()
