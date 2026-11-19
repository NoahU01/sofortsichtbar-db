-- Call-Transkripte alle 15 Minuten abholen (Edge Function transkripte-import).
-- Ohne eingerichteten Ordner antwortet die Funktion nur „nicht eingerichtet“.
select cron.schedule('transkripte-import-15min', '7,22,37,52 * * * *', $job$
  select net.http_post(
    url := 'https://udrcjopiixhlntmnsosj.supabase.co/functions/v1/transkripte-import',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-import-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'suche_import')),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000)
$job$);
