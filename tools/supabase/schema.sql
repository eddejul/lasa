-- Läsa: tabellerna för synken mellan iPaden och Windows-appen (fas 6).
-- Kör hela filen en gång i Supabase: SQL Editor, New query, klistra in, Run.
-- Varje rad tillhör den inloggade användaren. Reglerna (row level security) gör att ingen annan kan läsa
-- eller ändra dem, inte ens med projektets publika nyckel.

-- Läspositionen per bok. Boken känns igen på SHA-256 av filens innehåll (gemener, hex).
-- PDF: section är sidan (från 0). EPUB och text: section är kapitlet i bokens läsordning (från 0) och
-- progression hur långt in i kapitlet (0 till 1).
create table if not exists public.positions (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  book_id text not null,
  title text not null default '',
  kind text not null check (kind in ('pdf', 'reflow')),
  section integer not null default 0,
  progression double precision not null default 0,
  updated_at timestamptz not null,
  primary key (user_id, book_id)
);

-- Markeringar och anteckningar. Platsen är section och ett teckenintervall (start, length) i UTF-16:
-- PDF: i sidans text som PDFKit/pdf.js ger den. EPUB: i kapitlets text, all text i body i dokumentordning
-- utom skript och stilar. text är den markerade texten, så att markeringen kan letas upp om platsen skiljer.
create table if not exists public.highlights (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  book_id text not null,
  section integer not null,
  start integer not null,
  length integer not null,
  text text not null,
  color text not null,
  note text not null default '',
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false
);

create table if not exists public.bookmarks (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  book_id text not null,
  section integer not null,
  progression double precision not null default 0,
  label text not null default '',
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false
);

-- Sparade ord och repetitionen. language är 'sv' eller 'en'. due är sekunder sedan 1970 (UTC),
-- interval dagar. Repetitionen har en egen ändringstid, så att ordet och repetitionen synkas var för sig.
create table if not exists public.saved_words (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  lemma text not null,
  language text not null,
  word text not null default '',
  sentence text not null default '',
  book text not null default '',
  page integer not null default 0,
  lookups integer not null default 1,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false,
  due double precision,
  interval double precision,
  ease double precision,
  reps integer,
  lapses integer,
  review_updated_at timestamptz,
  primary key (user_id, lemma, language)
);

create index if not exists highlights_user_updated on public.highlights (user_id, updated_at);
create index if not exists bookmarks_user_updated on public.bookmarks (user_id, updated_at);
create index if not exists saved_words_user_updated on public.saved_words (user_id, updated_at);

alter table public.positions enable row level security;
alter table public.highlights enable row level security;
alter table public.bookmarks enable row level security;
alter table public.saved_words enable row level security;

drop policy if exists "egna rader" on public.positions;
drop policy if exists "egna rader" on public.highlights;
drop policy if exists "egna rader" on public.bookmarks;
drop policy if exists "egna rader" on public.saved_words;

create policy "egna rader" on public.positions for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "egna rader" on public.highlights for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "egna rader" on public.bookmarks for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "egna rader" on public.saved_words for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
