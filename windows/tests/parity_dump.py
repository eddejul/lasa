"""Skriver lookup.py:s svar som JSON, en rad per ord, för paritetstestet (parity.mjs).

  python windows/tests/parity_dump.py <ordbok.sqlite> <ordlista>

Varje ord slås upp både som svenska och som engelska, oavsett vilken del av testlistan det står i,
så att båda halvorna av logiken prövas på alla ord.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "dictionary"))

from lookup import Dictionary  # noqa: E402
from report import read_testwords  # noqa: E402


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    dictionary = Dictionary(sys.argv[1])
    for _language, word in read_testwords(sys.argv[2]):
        sv, en = dictionary.has(word)
        print(json.dumps({
            "word": word,
            "has": [sv, en],
            "sv": dictionary.lookup_sv(word),
            "en": dictionary.lookup_en(word),
        }, ensure_ascii=False))


if __name__ == "__main__":
    main()
