-- =====================================================================
-- Täglicher Abruf der Suchdaten (05:30 UTC) über die Edge Function
-- suche-import. Das Import-Secret liegt im Supabase Vault (Name
-- 'suche_import'), nicht hier – angelegt per SQL, gleicher Wert wie das
-- Function-Secret IMPORT_SECRET.
-- Beim Umzug auf das prod-Projekt die URL anpassen.
-- =====================================================================
create extension if not exists pg_net;

select cron.schedule('suche-import-taeglich', '30 5 * * *', $job$
  select net.http_post(
    url := 'https://udrcjopiixhlntmnsosj.supabase.co/functions/v1/suche-import',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-import-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'suche_import')),
    body := '{"tage": 10}'::jsonb,
    timeout_milliseconds := 120000)
$job$);
