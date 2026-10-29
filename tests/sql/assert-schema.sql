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

  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'products_fts_idx') then
    raise exception 'fehlender Index products_fts_idx';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'products_name_trgm_idx') then
    raise exception 'fehlender Index products_name_trgm_idx';
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_trgm') then
    raise exception 'pg_trgm fehlt';
  end if;
end $$;

do $$
declare
  problems text;
begin
  with expected(tbl, col, typ, not_null, defpat) as (
    values
      ('products','id','uuid',true,'^gen_random_uuid\(\)$'),
      ('products','sku','text',false,null),
      ('products','slug','text',false,null),
      ('products','name','text',true,null),
      ('products','description','text',false,null),
      ('products','price_cents','integer',false,null),
      ('products','currency','character(3)',true,'^''EUR''::bpchar$'),
      ('products','availability','text',false,null),
      ('products','category','text',false,null),
      ('products','brand','text',false,null),
      ('products','attributes','jsonb',true,'^''\{\}''::jsonb$'),
      ('products','image_url','text',false,null),
      ('products','product_url','text',true,null),
      ('products','source_hash','text',true,null),
      ('products','is_active','boolean',true,'^true$'),
      ('products','miss_count','smallint',true,'^0$'),
      ('products','first_seen_at','timestamp with time zone',true,'^now\(\)$'),
      ('products','last_seen_at','timestamp with time zone',true,'^now\(\)$'),
      ('products','updated_at','timestamp with time zone',true,'^now\(\)$'),
      ('pages','id','uuid',true,'^gen_random_uuid\(\)$'),
      ('pages','url','text',true,null),
      ('pages','title','text',false,null),
      ('pages','content_md','text',true,null),
      ('pages','topic','text',false,null),
      ('pages','content_hash','text',true,null),
      ('pages','updated_at','timestamp with time zone',true,'^now\(\)$'),
      ('crawl_runs','id','uuid',true,'^gen_random_uuid\(\)$'),
      ('crawl_runs','started_at','timestamp with time zone',true,'^now\(\)$'),
      ('crawl_runs','finished_at','timestamp with time zone',false,null),
      ('crawl_runs','status','text',true,'^''running''::text$'),
      ('crawl_runs','urls_total','integer',true,'^0$'),
      ('crawl_runs','urls_fetched','integer',true,'^0$'),
      ('crawl_runs','products_upserted','integer',true,'^0$'),
      ('crawl_runs','products_deactivated','integer',true,'^0$'),
      ('crawl_runs','errors','jsonb',true,'^''\[\]''::jsonb$'),
      ('callbacks','id','uuid',true,'^gen_random_uuid\(\)$'),
      ('callbacks','name','text',false,null),
      ('callbacks','phone','text',true,null),
      ('callbacks','reason','text',false,null),
      ('callbacks','created_at','timestamp with time zone',true,'^now\(\)$'),
      ('callbacks','handled_at','timestamp with time zone',false,null),
      ('calls','id','uuid',true,'^gen_random_uuid\(\)$'),
      ('calls','conversation_id','text',false,null),
      ('calls','started_at','timestamp with time zone',false,null),
      ('calls','duration_sec','integer',false,null),
      ('calls','summary','text',false,null),
      ('calls','tool_calls','jsonb',true,'^''\[\]''::jsonb$'),
      ('calls','outcome','text',false,null),
      ('calls','created_at','timestamp with time zone',true,'^now\(\)$')
  ),
  actual as (
    select e.tbl, e.col, e.typ, e.not_null, e.defpat,
           a.attname is not null as is_found,
           format_type(a.atttypid, a.atttypmod) as actual_typ,
           a.attnotnull as actual_not_null,
           pg_get_expr(d.adbin, d.adrelid) as actual_def
    from expected e
    left join pg_class c on c.oid = to_regclass('public.' || e.tbl)
    left join pg_attribute a on a.attrelid = c.oid and a.attname = e.col
                            and a.attnum > 0 and not a.attisdropped
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  )
  select string_agg(
           format('%s.%s (%s)', tbl, col,
             concat_ws('; ',
               case when not actual.is_found then 'Spalte fehlt' end,
               case when actual.is_found and actual_typ is distinct from typ then 'typ=' || actual_typ end,
               case when actual.is_found and actual_not_null is distinct from not_null then 'not_null=' || actual_not_null end,
               case when actual.is_found and defpat is not null and coalesce(actual_def, '') !~ defpat then 'default=' || coalesce(actual_def, '<keiner>') end,
               case when actual.is_found and defpat is null and actual_def is not null then 'unerwarteter default=' || actual_def end
             )),
           ', ' order by tbl, col)
    into problems
  from actual
  where not actual.is_found
     or actual_typ is distinct from typ
     or actual_not_null is distinct from not_null
     or (defpat is not null and coalesce(actual_def, '') !~ defpat)
     or (defpat is null and actual_def is not null);

  if problems is not null then
    raise exception 'Spaltendefinitionen weichen ab: %', problems;
  end if;
end $$;

do $$
declare missing text;
begin
  if not exists (
    select 1
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'products' and con.contype = 'c'
      and pg_get_constraintdef(con.oid) like '%availability%'
      and pg_get_constraintdef(con.oid) like '%''instock''%'
      and pg_get_constraintdef(con.oid) like '%''outofstock''%'
      and pg_get_constraintdef(con.oid) like '%''preorder''%'
      and pg_get_constraintdef(con.oid) like '%''unknown''%'
  ) then
    raise exception 'CHECK-Constraint products.availability fehlt oder ist unvollstaendig';
  end if;

  if not exists (
    select 1
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'crawl_runs' and con.contype = 'c'
      and pg_get_constraintdef(con.oid) like '%status%'
      and pg_get_constraintdef(con.oid) like '%''running''%'
      and pg_get_constraintdef(con.oid) like '%''success''%'
      and pg_get_constraintdef(con.oid) like '%''partial''%'
      and pg_get_constraintdef(con.oid) like '%''failed''%'
  ) then
    raise exception 'CHECK-Constraint crawl_runs.status fehlt oder ist unvollstaendig';
  end if;

  select string_agg(col, ', ') into missing
  from unnest(array['sku','slug','product_url']) col
  where not exists (
    select 1
    from pg_index i
    join pg_class c on c.oid = i.indrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = i.indrelid
                        and a.attnum = any (i.indkey::smallint[])
    where n.nspname = 'public' and c.relname = 'products'
      and i.indisunique and i.indisvalid and i.indnatts = 1
      and a.attname = col
  );
  if missing is not null then
    raise exception 'fehlende UNIQUE-Constraints: %', missing;
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'products_active_idx'
      and indexdef ilike '%where%is_active%'
  ) then
    raise exception 'products_active_idx fehlt oder ist nicht partiell';
  end if;

  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'products'
      and t.tgname = 'products_set_updated_at'
      and not t.tgisinternal
      and (t.tgtype & 19) = 19
      and t.tgfoid = 'public.set_updated_at()'::regprocedure
  ) then
    raise exception 'Trigger products_set_updated_at fehlt oder ist falsch konfiguriert';
  end if;
end $$;
