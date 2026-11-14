-- =====================================================================
-- Buffer-Abruf zweimal täglich (06:40 und 17:40 UTC). Buffer aktualisiert
-- die Kennzahlen einmal am Tag, die Uhrzeit ist nicht dokumentiert.
-- Secret wie bei den anderen Importen im Vault ('suche_import').
-- =====================================================================
select cron.schedule('buffer-import-2x-taeglich', '40 6,17 * * *', $job$
  select net.http_post(
    url := 'https://udrcjopiixhlntmnsosj.supabase.co/functions/v1/buffer-import',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-import-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'suche_import')),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000)
$job$);
