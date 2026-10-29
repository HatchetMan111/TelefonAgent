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
  base as (
    select p.*,
           ts_rank(
             to_tsvector('german', coalesce(p.name,'') || ' ' || coalesce(p.description,'')),
             (select ts from qq)
           ) as rank
    from products p
    where p.is_active
      and (p_category is null or p.category = p_category)
      and (p_max_price_cents is null or p.price_cents <= p_max_price_cents)
      and (not p_in_stock_only or p.availability = 'instock')
  ),
  fts as (
    select * from base
    where to_tsvector('german', coalesce(name,'') || ' ' || coalesce(description,''))
          @@ (select ts from qq)
    order by rank desc
    limit p_limit
  ),
  fuzzy as (
    select * from base
    where not exists (select 1 from fts)
      and similarity(name, coalesce(nullif(trim(q), ''), '')) > 0.15
    order by similarity(name, coalesce(nullif(trim(q), ''), '')) desc
    limit p_limit
  )
  select jsonb_build_object(
    'as_of', to_char(now(), 'YYYY-MM-DD'),
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
