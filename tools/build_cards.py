#!/usr/bin/env python3
"""
Regenerate cards.json (used by the web app) and cards.csv (optional Supabase seed)
from the-fab-cube/flesh-and-blood-cards.

Run this whenever a new set drops:

    python3 tools/build_cards.py

Output: ../cards.json, ../cards.csv relative to this file's parent.
Only dependency is pandas + requests.
"""
import csv, io, json, os, sys
import pandas as pd
import requests

BASE = "https://raw.githubusercontent.com/the-fab-cube/flesh-and-blood-cards/develop/csvs/english/"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
IMG_PREFIX = "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/"

CLASSES = ["Generic", "Warrior", "Guardian", "Mechanologist", "Runeblade", "Ninja",
           "Brute", "Illusionist", "Assassin", "Wizard", "Ranger", "Pirate",
           "Necromancer", "Bard", "Adjudicator", "Merchant", "Shapeshifter",
           "Thief", "Mercenary"]

TALENTS = ["Lightning", "Shadow", "Light", "Draconic", "Elemental", "Mystic",
           "Earth", "Revered", "Ice", "Reviled", "Chaos", "Royal", "Ash", "Chi"]

# Easiest to hardest to get hold of. A card is ranked by its EASIEST printing:
# if it exists as a Common anywhere, a Marvel version elsewhere doesn't make it
# a hard card to own. Promo sits mid-ladder and only applies to promo-only cards.
RARITY_ORDER = ["B", "T", "C", "R", "S", "M", "P", "L", "V", "F"]


def fetch(name):
    print(f"  fetching {name}")
    r = requests.get(BASE + name, timeout=60)
    r.raise_for_status()
    return pd.read_csv(io.StringIO(r.text), sep="\t", dtype=str).fillna("")


def kind_of(types):
    for k in ("Hero", "Demi-Hero", "Token", "Weapon", "Equipment"):
        if k in types:
            return "Hero" if k == "Demi-Hero" else k
    return "Deck"


def main():
    print("Building card data")
    card = fetch("card.csv")
    printing = fetch("card-printing.csv")

    # one image + the set list per card, collapsed across all printings
    extras = {}
    for uid, grp in printing.groupby("Card Unique ID"):
        sets = list(dict.fromkeys(s for s in grp["Set ID"] if s))
        rar = sorted({r for r in grp["Rarity"] if r in RARITY_ORDER},
                     key=RARITY_ORDER.index)
        img = next((u for u in grp["Image URL"] if u), "")
        if img.startswith(IMG_PREFIX):
            img = img[len(IMG_PREFIX):]          # stored short, rebuilt in the app
        cid = next((c for c in grp["Card ID"] if c), "")
        extras[uid] = (sets, rar, img, cid)

    rows = []
    for _, r in card.iterrows():
        types = [t.strip() for t in r["Types"].split(",")]
        sets, rar, img, cid = extras.get(r["Unique ID"], ([], [], "", ""))
        rows.append({
            "i": r["Unique ID"],
            "n": r["Name"],
            "p": r["Pitch"],
            "c": [t for t in types if t in CLASSES],
            "t": [t for t in types if t in TALENTS],
            "k": kind_of(types),
            "tt": r["Type Text"],
            "co": r["Cost"], "po": r["Power"], "df": r["Defense"],
            "cc": 0 if r["CC Legal"] == "No" else 1,
            "r": rar,
            "rk": RARITY_ORDER.index(rar[0]) if rar else len(RARITY_ORDER),
            "s": sets, "g": img, "id": cid,
        })

    rows.sort(key=lambda x: (x["n"].lower(), x["p"] or "9"))

    with open(os.path.join(OUT, "cards.json"), "w") as f:
        json.dump({"prefix": IMG_PREFIX, "cards": rows}, f, separators=(",", ":"))

    # optional Supabase seed. Pipe-delimited multi-values so any CSV importer copes.
    with open(os.path.join(OUT, "cards.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["card_id", "name", "pitch", "classes", "talents", "kind",
                    "type_text", "cost", "power", "defense", "cc_legal",
                    "rarities", "easiest_rarity", "sets", "printing_code", "image_url"])
        for r in rows:
            w.writerow([r["i"], r["n"], r["p"] or "", "|".join(r["c"]), "|".join(r["t"]),
                        r["k"], r["tt"], r["co"], r["po"], r["df"],
                        "true" if r["cc"] else "false",
                        "|".join(r["r"]), r["r"][0] if r["r"] else "",
                        "|".join(r["s"]), r["id"],
                        IMG_PREFIX + r["g"] if r["g"] and "/" not in r["g"] else r["g"]])

    size = os.path.getsize(os.path.join(OUT, "cards.json")) / 1024
    print(f"Wrote {len(rows)} cards  ({size:.0f} KB in cards.json)")


if __name__ == "__main__":
    sys.exit(main())
