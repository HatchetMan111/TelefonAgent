create extension if not exists pg_trgm;
create extension if not exists pgcrypto;

create table if not exists products (
  id            uuid primary key default gen_random_uuid(),
  sku           text unique,
  slug          text unique,
  name          text not null,
  description   text,
  price_cents   integer,
  currency      char(3) not null default 'EUR',
  availability  text check (availability in ('instock','outofstock','preorder','unknown')),
  category      text,
  brand         text,
  attributes    jsonb not null default '{}'::jsonb,
  image_url     text,
  product_url   text not null,
  source_hash   text not null,
  is_active     boolean not null default true,
  miss_count    smallint not null default 0,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists products_fts_idx on products
  using gin (to_tsvector('german', coalesce(name,'') || ' ' || coalesce(description,'')));
create index if not exists products_name_trgm_idx on products using gin (name gin_trgm_ops);
create index if not exists products_active_idx on products (is_active) where is_active;
create unique index if not exists products_product_url_key on products (product_url);

create table if not exists pages (
  id           uuid primary key default gen_random_uuid(),
  url          text unique not null,
  title        text,
  content_md   text not null,
  topic        text,
  content_hash text not null,
  updated_at   timestamptz not null default now()
);

create table if not exists crawl_runs (
  id                   uuid primary key default gen_random_uuid(),
  started_at           timestamptz not null default now(),
  finished_at          timestamptz,
  status               text not null default 'running'
                         check (status in ('running','success','partial','failed')),
  urls_total           integer not null default 0,
  urls_fetched         integer not null default 0,
  products_upserted    integer not null default 0,
  products_deactivated integer not null default 0,
  errors               jsonb not null default '[]'::jsonb
);

create table if not exists callbacks (
  id         uuid primary key default gen_random_uuid(),
  name       text,
  phone      text not null,
  reason     text,
  created_at timestamptz not null default now(),
  handled_at timestamptz
);

create table if not exists calls (
  id              uuid primary key default gen_random_uuid(),
  conversation_id text unique,
  started_at      timestamptz,
  duration_sec    integer,
  summary         text,
  tool_calls      jsonb not null default '[]'::jsonb,
  outcome         text,
  created_at      timestamptz not null default now()
);

create or replace function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists products_set_updated_at on products;
create trigger products_set_updated_at before update on products
for each row execute function set_updated_at();
