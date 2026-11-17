-- =====================================================================
-- Newsletter-Versand: jede Minute einen Schwung abholen und schicken.
-- Ohne SES-Zugang antwortet die Function sofort mit „nicht eingerichtet“.
-- Secret wie bei den Importen im Vault ('suche_import').
-- =====================================================================
select cron.schedule('newsletter-versand-1min', '* * * * *', $job$
  select net.http_post(
    url := 'https://udrcjopiixhlntmnsosj.supabase.co/functions/v1/newsletter-versand',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-import-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'suche_import')),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000)
$job$);
