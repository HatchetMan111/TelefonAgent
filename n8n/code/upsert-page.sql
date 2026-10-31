insert into pages (url, title, content_md, topic, content_hash, updated_at)
values ($1, $2, $3, $4, md5($3), now())
on conflict (url) do update set
  title = excluded.title,
  content_md = excluded.content_md,
  topic = excluded.topic,
  content_hash = excluded.content_hash,
  updated_at = now();
