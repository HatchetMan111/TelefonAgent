-- Performance-Nachschärfung für search_products (Review 2026-11-07):
-- 1. Der FTS-Zweig fragt products direkt mit dem @@-Filter ab, damit der
--    Ausdrucks-Index products_fts_idx genutzt werden kann. Vorher lief die
--    doppelt referenzierte CTE base ohne @@-Filter über alle aktiven Produkte.
-- 2. Der Fuzzy-Zweig behält similarity() > 0.15 (bewusst lockerer als der
--    %-Operator mit Default-Schwelle 0.3); er greift nur, wenn FTS nichts findet.
-- 3. Zusätzliche Indizes für die nächtlichen Zähler-Queries (Lauf-Abschluss)
--    und den pages-Lookup nach topic.

create or replace function search_products(
  q text,
  p_category text default null,
  p_max_price_cents integer default null,
  p_in_stock_only boolean default false,
  p_limit integer default 5
) returns jsonb
language sql stable as $$
  with qq as (
    select websearch_to_tsquery('german', coalesce(nullif(trim(q), ''), 'x')) as ts
  ),
  fts as (
    select p.*,
           ts_rank(
             to_tsvector('german', coalesce(p.name,'') || ' ' || coalesce(p.description,'')),
             (select ts from qq)
           ) as rank
    from products p
    where p.is_active
      and to_tsvector('german', coalesce(p.name,'') || ' ' || coalesce(p.description,''))
          @@ (select ts from qq)
      and (p_category is null or p.category = p_category)
      and (p_max_price_cents is null or p.price_cents <= p_max_price_cents)
      and (not p_in_stock_only or p.availability = 'instock')
    order by rank desc
    limit greatest(0, least(coalesce(p_limit, 5), 5))
  ),
  fuzzy as (
    select p.*,
           similarity(p.name, coalesce(nullif(trim(q), ''), '')) as sim
    from products p
    where p.is_active
      and not exists (select 1 from fts)
      and similarity(p.name, coalesce(nullif(trim(q), ''), '')) > 0.15
      and (p_category is null or p.category = p_category)
      and (p_max_price_cents is null or p.price_cents <= p_max_price_cents)
      and (not p_in_stock_only or p.availability = 'instock')
    order by sim desc
    limit greatest(0, least(coalesce(p_limit, 5), 5))
  )
  select jsonb_build_object(
    'as_of', to_char(now() at time zone 'Europe/Berlin', 'YYYY-MM-DD'),
    'products', coalesce(jsonb_agg(jsonb_build_object(
      'sku', sku,
      'name', name,
      'price_eur', round(price_cents / 100.0, 2),
      'availability', availability,
      'url', product_url,
      'last_seen', last_seen_at
    )), '[]'::jsonb)
  )
  from (select * from fts union all select * from fuzzy) t;
$$;

create index if not exists products_last_seen_idx on products (last_seen_at);
create index if not exists products_updated_idx on products (updated_at);
create index if not exists pages_topic_idx on pages (topic);
