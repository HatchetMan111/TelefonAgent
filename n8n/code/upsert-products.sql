insert into products (
  sku, slug, name, description, price_cents, currency, availability,
  category, brand, attributes, image_url, product_url, source_hash, last_seen_at
)
select
  x.sku, x.slug, x.name, x.description, x.price_cents, coalesce(x.currency, 'EUR'),
  x.availability, x.category, x.brand, coalesce(x.attributes, '{}'::jsonb), x.image_url,
  x.product_url,
  md5(concat_ws('|', x.sku, x.name, coalesce(x.description,''), x.price_cents::text,
                x.availability, coalesce(x.category,''), coalesce(x.brand,''), x.product_url)),
  now()
from jsonb_to_recordset($1::jsonb) as x(
  sku text, slug text, name text, description text, price_cents int, currency text,
  availability text, category text, brand text, attributes jsonb, image_url text, product_url text
)
on conflict (sku) do update set
  sku = excluded.sku,
  slug = excluded.slug,
  name = excluded.name,
  description = excluded.description,
  price_cents = excluded.price_cents,
  currency = excluded.currency,
  availability = excluded.availability,
  category = excluded.category,
  brand = excluded.brand,
  attributes = excluded.attributes,
  image_url = excluded.image_url,
  product_url = excluded.product_url,
  source_hash = excluded.source_hash,
  last_seen_at = now(),
  miss_count = 0,
  is_active = true;
