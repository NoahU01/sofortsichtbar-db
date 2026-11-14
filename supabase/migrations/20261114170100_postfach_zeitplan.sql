-- =====================================================================
-- Postfächer und Kalender alle 15 Minuten abrufen (Edge Function
-- postfach-import). Gleiches Vault-Secret wie beim Suchimport.
-- Beim Umzug auf das prod-Projekt die URL anpassen.
-- =====================================================================
select cron.schedule('postfach-import-15min', '*/15 * * * *', $job$
  select net.http_post(
    url := 'https://udrcjopiixhlntmnsosj.supabase.co/functions/v1/postfach-import',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-import-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'suche_import')),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000)
$job$);
