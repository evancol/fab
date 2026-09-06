-- ============================================================================
--  Flesh and Blood collection tracker — Supabase schema
--  Paste this whole file into the Supabase SQL editor and run it once.
--
--  Access model: no login. Each person gets a random 16-character collection
--  code that acts as a bearer token. The tables themselves are NOT reachable
--  with the anon key -- every read and write goes through a security-definer
--  function that requires the code. So a stranger holding your anon key still
--  can't enumerate or dump anyone's collection.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- collections
create table if not exists public.collection (
  code         text primary key,
  label        text,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

-- Quantity buckets, not exact counts. Deck cards use 1/3/5/8, where 1 shows as
-- "<3" because 3 is the playset. Equipment, weapons and heroes use 1/2/3/5,
-- since you can only run one per deck and what matters is how many decks you
-- can build. No row at all means none owned.
--
-- -1 means "not tracking": a card you've decided you don't want, which drops
-- out of every total instead of sitting in the missing pile forever.
create table if not exists public.collection_card (
  code       text     not null references public.collection(code) on delete cascade,
  card_id    text     not null,          -- fab-cube "Unique ID": one row per name + pitch
  qty        smallint not null check (qty in (-1, 1, 2, 3, 5, 8)),
  updated_at timestamptz not null default now(),
  primary key (code, card_id)
);

create index if not exists collection_card_card_idx on public.collection_card (card_id);

-- Already ran an earlier version of this file? This widens the constraint
-- without touching your data. Safe to run more than once.
alter table public.collection_card drop constraint if exists collection_card_qty_check;
alter table public.collection_card add  constraint collection_card_qty_check
  check (qty in (-1, 1, 2, 3, 5, 8));

-- Deliberately no foreign key to public.card. Card data refreshes on its own
-- schedule from the fab-cube repo, and a new set shouldn't be able to break
-- writes for someone whose reference table hasn't been reloaded yet.

-- ------------------------------------------------- optional reference table
-- The web app reads cards.json straight from GitHub Pages and never touches
-- this table. It exists so you can write SQL against your own collection.
-- Load it from cards.csv via Table editor -> Import data from CSV.
create table if not exists public.card (
  card_id       text primary key,
  name          text not null,
  pitch         smallint,
  classes       text,          -- pipe-delimited, e.g. 'Guardian|Warrior'
  talents       text,
  kind          text,          -- Deck | Equipment | Weapon | Hero | Token
  type_text     text,
  cost          text,
  power         text,
  defense       text,
  cc_legal      boolean,
  sets          text,          -- pipe-delimited set codes
  printing_code text,
  image_url     text
);

create index if not exists card_name_idx on public.card (lower(name));

-- ------------------------------------------------------------------- lockdown
alter table public.collection      enable row level security;
alter table public.collection_card enable row level security;
alter table public.card            enable row level security;

-- No policies on collection / collection_card, so anon gets nothing directly.
-- Card data is public game information, so it can be read freely.
drop policy if exists card_is_public on public.card;
create policy card_is_public on public.card for select to anon, authenticated using (true);

revoke all on public.collection      from anon, authenticated;
revoke all on public.collection_card from anon, authenticated;
grant  select on public.card         to   anon, authenticated;

-- ------------------------------------------------------------------ functions

-- 16 characters drawn from 32 symbols (0, O, 1 and I dropped so nobody
-- misreads a code out loud) = 80 bits of entropy.
create or replace function public.gen_collection_code()
returns text language sql volatile as $$
  select string_agg(
           substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
                  1 + (get_byte(b, i) % 32), 1), '' order by i)
  from (select extensions.gen_random_bytes(16) as b) s,
       generate_series(0, 15) i;
$$;

-- Create a collection. Returns the new code.
create or replace function public.new_collection(p_label text default null)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_code text;
begin
  if length(coalesce(p_label, '')) > 60 then
    raise exception 'Label too long';
  end if;
  loop
    v_code := gen_collection_code();
    exit when not exists (select 1 from collection where code = v_code);
  end loop;
  insert into collection (code, label) values (v_code, nullif(trim(p_label), ''));
  return v_code;
end $$;

-- Everything owned in one collection. Also confirms the code is real.
create or replace function public.get_collection(p_code text)
returns table (card_id text, qty smallint)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from collection c where c.code = p_code) then
    raise exception 'Unknown collection code' using errcode = 'no_data_found';
  end if;
  update collection c set last_seen_at = now() where c.code = p_code;
  return query
    select cc.card_id, cc.qty from collection_card cc where cc.code = p_code;
end $$;

-- Set one card. Pass 0 to remove it.
create or replace function public.set_qty(p_code text, p_card_id text, p_qty smallint)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from collection c where c.code = p_code) then
    raise exception 'Unknown collection code' using errcode = 'no_data_found';
  end if;

  if p_qty = 0 then
    delete from collection_card where code = p_code and card_id = p_card_id;
  else
    insert into collection_card (code, card_id, qty)
    values (p_code, p_card_id, p_qty)
    on conflict (code, card_id)
      do update set qty = excluded.qty, updated_at = now();
  end if;
end $$;

-- Bulk version, for flushing an offline queue or importing a list.
-- p_items looks like: [{"card_id":"abc...","qty":3}, {"card_id":"def...","qty":0}]
create or replace function public.set_many(p_code text, p_items jsonb)
returns integer
language plpgsql security definer set search_path = public as $$
declare v_item jsonb; v_n integer := 0;
begin
  if not exists (select 1 from collection c where c.code = p_code) then
    raise exception 'Unknown collection code' using errcode = 'no_data_found';
  end if;
  if jsonb_array_length(p_items) > 2000 then
    raise exception 'Too many items in one call';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    perform set_qty(p_code, v_item->>'card_id', (v_item->>'qty')::smallint);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ------------------------------------------------------------------- grants
revoke all on function public.gen_collection_code() from public, anon, authenticated;

grant execute on function public.new_collection(text)              to anon, authenticated;
grant execute on function public.get_collection(text)              to anon, authenticated;
grant execute on function public.set_qty(text, text, smallint)     to anon, authenticated;
grant execute on function public.set_many(text, jsonb)             to anon, authenticated;

-- ============================================================================
--  Handy queries once cards.csv is loaded
-- ============================================================================
-- Everything you're short of in one class:
--
--   select c.name, c.pitch, coalesce(cc.qty, 0) as owned
--   from card c
--   left join collection_card cc
--          on cc.card_id = c.card_id and cc.code = 'YOUR-CODE-HERE'
--   where c.classes like '%Guardian%'
--     and c.kind = 'Deck'
--     and coalesce(cc.qty, 0) < 3
--   order by c.name, c.pitch;
--
-- Playset completion by class:
--
--   select unnest(string_to_array(c.classes, '|')) as class,
--          count(*) filter (where coalesce(cc.qty, 0) >= 3) as playsets,
--          count(*)                                         as printed
--   from card c
--   left join collection_card cc
--          on cc.card_id = c.card_id and cc.code = 'YOUR-CODE-HERE'
--   where c.kind = 'Deck'
--   group by 1 order by 1;
