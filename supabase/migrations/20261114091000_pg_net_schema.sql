-- pg_net gehört ins Schema extensions, nicht public (Advisor 0014).
-- pg_net kann kein SET SCHEMA – neu anlegen. Der Zeitplan ruft net.http_post
-- per Namen auf und ist davon nicht betroffen.
drop extension if exists pg_net;
create extension pg_net with schema extensions;
