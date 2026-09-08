# Flesh and Blood collection tracker

Track how many of each Flesh and Blood card you own. All 4,952 cards, all classes.
Counted once per card — a card printed in three sets is still one row, and you
only ever need 8 of it in total.

Quantities are buckets rather than exact counts: **&lt;3**, **3**, **5**, **8**, or nothing.

Static front end on GitHub Pages, Postgres on Supabase, no server in between.

---

## 1. Supabase

1. Create a project at supabase.com. Any region, free tier is plenty.
2. Open **SQL Editor**, paste all of `supabase.sql`, run it.
3. Go to **Project settings → Data API** and copy the project URL, then
   **Project settings → API keys** and copy the `anon` / publishable key.
4. `cp config.example.js config.js`, put both values in it, and commit it.

The anon key is public by design and it's fine to commit it. It doesn't grant
access to anything on its own: the `collection` and `collection_card` tables have
RLS on with no policies, so they can't be read or written directly. Everything
goes through `get_collection`, `set_qty` and `set_many`, all of which demand a
collection code. Without a code the key gets you the card reference table and
nothing else.

**Optional.** To query your collection in SQL, load the card reference table:
**Table editor → `card` → Import data from CSV**, pick `cards.csv`. The app never
reads this table — it's there for you. Example queries are at the bottom of
`supabase.sql`.

## 2. GitHub Pages

```bash
git init
git add .
git commit -m "Flesh and Blood collection tracker"
git branch -M main
git remote add origin git@github.com:YOURNAME/fab-collection.git
git push -u origin main
```

Then **Settings → Pages → Source: Deploy from a branch → main / (root)**.
Live at `https://YOURNAME.github.io/fab-collection/` in about a minute.

A custom domain later is just a `CNAME` file and a DNS record. Nothing else
changes, because the database was never on the same host as the pages.

## 3. Giving someone access

The app opens on a class grid showing how far along each class is, so nobody
lands in a list of 4,952 cards. Pick a class to get the card list, and the
arrow at the top left goes back.

Open the app, hit **Create a new collection**, and you get a 16-character code.
That code *is* the account — anyone holding it can read and edit that collection,
and there's no password to reset if it's lost. Create a separate collection per
person, or hand out the same code to share one.

Codes are 80 bits of randomness, so they can't be guessed, but treat them like a
door key rather than a username.

## 4. About `config.js`

`config.js` is **not** in the release zip, so unpacking a new version over your
repo can't overwrite it. If it gets clobbered some other way, the app falls back
to the last settings that worked on your device and says so under ⚙, rather than
silently failing to reach the server. A copy with placeholders still in it, or
none at all, shows a setup panel where you can paste the URL and key directly.

## 5. Keeping card data current

When a set releases:

```bash
pip install pandas requests
python3 tools/build_cards.py
git commit -am "Card data through <SET>"
git push
```

That rewrites `cards.json` (what the app reads) and `cards.csv` (the optional
Supabase seed) from
[the-fab-cube/flesh-and-blood-cards](https://github.com/the-fab-cube/flesh-and-blood-cards).
Nothing in the database needs to change — quantities are stored against the
card's stable ID, so a re-import never disturbs what you own.

---

## Files

| | |
|---|---|
| `index.html` | The whole app. No build step, no framework. |
| `config.example.js` | Template for `config.js`, the only file you edit. |
| `cards.json` | Card data, ~1 MB, ~200 KB over the wire. Cached after first load. |
| `cards.csv` | Same data for the optional Supabase reference table. |
| `supabase.sql` | Schema, RLS, and the four functions the app calls. Re-runnable. |
| `tools/build_cards.py` | Regenerates both card files. |
| `manifest.json`, `icon.png` | Makes "Add to Home Screen" behave like an app. |

## Notes on the data model

- One row per **card**, meaning name plus pitch. Red, yellow and blue
  *Aftershock* are three separate cards you buy separately, so they're tracked
  separately. Printings are collapsed — an entry is never per-set.
- Deck cards use **&lt;3 / 3 / 5 / 8** and count as complete at 3 — except a deck
  card whose *easiest available printing* is Legendary, which drops to the
  equipment scale below. Nobody is chasing a playset of a Legendary, and a card
  that also has a cheaper printing (a Promo or Majestic alongside the
  Legendary) isn't affected — only the ones that are Legendary-only.
- Equipment, weapons, heroes, and Legendary-only deck cards use **1 / 2 / 3 / 5**
  and count as complete at 1, since the question for those is how many decks
  you can build at once, not how many copies run in one.
- **skip** marks a card you've decided you don't want. It drops out of every
  total — the denominator shrinks rather than the card sitting in the missing
  pile forever — and the "Not tracking" filter lists what you've set aside.
- Stored as `-1, 1, 2, 3, 5, 8`, where `-1` is skip. A card you own none of and
  haven't skipped has no row at all.
- Every row carries `updated_at`. The app shows it next to the set codes as
  "4 days ago", with the exact date and time on hover, and ⚙ shows the most
  recent change across the whole collection. Clearing a card back to nothing
  removes its row, so it loses its timestamp too.
- Edits save locally first and sync in the background, so the app keeps working
  on bad venue wifi and catches up when it reconnects. Nothing is sent before
  it's written to `localStorage`, so a failed sync never loses an edit.
- If saves stall, open ⚙. A genuine network problem says "offline"; anything the
  database refused shows the actual Postgres message. **Retry saving now** pushes
  again, and **Download full backup** writes a JSON file of everything including
  skips, which **Restore from backup** reads back. A rejected card no longer
  blocks the rest of the queue — the batch falls back to one call per card.
- **Rarity** is folded up from printings to the card, and a card is ranked by its
  *easiest* printing. *Enlightened Strike* has a Marvel version, but it's a
  Majestic for sorting purposes, because a Marvel printing doesn't make a card
  you can already buy any harder to get. Every rarity it was printed at shows
  when you tap the card. To rank by the scarcest printing instead, swap the
  `RARITY_ORDER.index(rar[0])` in `tools/build_cards.py` for `rar[-1]`.
