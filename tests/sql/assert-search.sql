\set ON_ERROR_STOP on
truncate products cascade;

insert into products (sku, slug, name, description, price_cents, availability, category, product_url, source_hash)
values
  ('REGEN-42', 'regenschuh-42', 'Regenschuh Urban 42 schwarz', 'Wasserdichter Schuh', 8990, 'instock', 'Schuhe', 'https://shop.example/produkt/regenschuh-42', 'h1'),
  ('REGEN-43', 'regenschuh-43', 'Regenschuh Urban 43 schwarz', 'Wasserdichter Schuh', 8990, 'outofstock', 'Schuhe', 'https://shop.example/produkt/regenschuh-43', 'h2'),
  ('JACKE-1', 'regenjacke-1', 'Regenjacke Trail', 'Leichte Jacke', 12990, 'instock', 'Jacken', 'https://shop.example/produkt/regenjacke-1', 'h3'),
  ('TEE-1', 'teebeutel-1', 'Teebeutel Kamille', 'Tee', 490, 'instock', 'Tee', 'https://shop.example/produkt/teebeutel-1', 'h4');

do $$
declare r jsonb;
begin
  -- exakter Treffer
  r := search_products('Regenschuh Urban 42', null, null, false, 5);
  if jsonb_array_length(r->'products') <> 1 then
    raise exception 'exakter Treffer: erwartet 1, war %', jsonb_array_length(r->'products');
  end if;
  if (r->'products'->0->>'price_eur')::numeric <> 89.90 then
    raise exception 'Preis falsch: %', r->'products'->0->>'price_eur';
  end if;
  if r->>'as_of' !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'as_of falsch: %', r->>'as_of';
  end if;

  -- Tippfehler / Trigram-Fallback
  r := search_products('Regenschu', null, null, false, 5);
  if jsonb_array_length(r->'products') = 0 then
    raise exception 'Trigram-Fallback lieferte nichts';
  end if;

  -- Preisfilter
  r := search_products('Regen', null, 10000, false, 5);
  if exists (select 1 from jsonb_array_elements(r->'products') p where (p->>'price_eur')::numeric > 100) then
    raise exception 'Preisfilter verletzt';
  end if;

  -- Verfügbarkeit
  r := search_products('Regenschuh', null, null, true, 5);
  if exists (select 1 from jsonb_array_elements(r->'products') p where p->>'sku' = 'REGEN-43') then
    raise exception 'outofstock-Produkt im instock-Filter';
  end if;

  -- leere Suche darf nicht crashen
  r := search_products('', null, null, false, 5);
  if jsonb_typeof(r->'products') <> 'array' then
    raise exception 'leere Suche lieferte kein Array';
  end if;
end $$;
