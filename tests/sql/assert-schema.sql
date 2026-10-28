\set ON_ERROR_STOP on
do $$
declare missing text;
begin
  select string_agg(t, ', ') into missing
  from unnest(array['products','pages','crawl_runs','callbacks','calls']) t
  where to_regclass('public.' || t) is null;
  if missing is not null then
    raise exception 'fehlende Tabellen: %', missing;
  end if;

  if not exists (select 1 from pg_indexes where indexname = 'products_fts_idx') then
    raise exception 'fehlender Index products_fts_idx';
  end if;
  if not exists (select 1 from pg_indexes where indexname = 'products_name_trgm_idx') then
    raise exception 'fehlender Index products_name_trgm_idx';
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_trgm') then
    raise exception 'pg_trgm fehlt';
  end if;
end $$;
