-- Mehr Firmengruppen (Versicherer mit mehreren Einträgen) und Instagram-Namen mit „sv…“ → SV
create or replace function core.firmengruppe_erkennen(p_name text, p_hinweis text default null)
returns text language sql immutable set search_path = '' as $$
  select case
    when x ~* '(sparkassen-?versicherung|(^|[^a-z])sv([^a-z]|$)|sv-team|svteam)' or coalesce(p_hinweis, '') ~* '(^|\s)sv' then 'SV SparkassenVersicherung'
    when x ~* '(^|[^a-z])lvm' then 'LVM'
    when x ~* 'allianz' then 'Allianz'
    when x ~* '(^|[^a-z])axa' then 'AXA'
    when x ~* 'zurich' then 'Zurich'
    when x ~* '((^|[^a-z])vkb([^a-z]|$)|versicherungskammer)' then 'Versicherungskammer Bayern'
    when x ~* '(^|[^a-z])lbs([^a-z]|$)' then 'LBS'
    when x ~* '(^|[^a-z])ergo([^a-z]|$)' then 'ERGO'
    when x ~* '(^|[^a-z])huk' then 'HUK-Coburg'
    when x ~* '(r\+v|(^|[^a-z])ruv([^a-z]|$))' then 'R+V'
    when x ~* 'signal.?iduna' then 'Signal Iduna'
    when x ~* 'generali' then 'Generali'
    when x ~* 'debeka' then 'Debeka'
    when x ~* 'provinzial' then 'Provinzial'
    when x ~* 'gothaer' then 'Gothaer'
    when x ~* 'devk' then 'DEVK'
    when x ~* '(württembergische|wuerttembergische|wüstenrot|wuestenrot)' then 'W&W'
    when x ~* 'continentale' then 'Continentale'
    when x ~* 'barmenia' then 'Barmenia'
    when x ~* 'nürnberger|nuernberger' then 'Nürnberger'
    when x ~* '(^|[^a-z])arag([^a-z]|$)' then 'ARAG'
    when x ~* '(^|[^a-z])bgv([^a-z]|$)|badische versicherung' then 'BGV Badische Versicherungen'
    when x ~* 'canada life' then 'Canada Life'
    when x ~* 'concordia' then 'Concordia'
    when x ~* 'hansemerkur' then 'HanseMerkur'
    when x ~* '(^|[^a-z])hdi([^a-z]|$)' then 'HDI'
    when x ~* 'helvetia' then 'Helvetia'
    when x ~* '(^|[^a-z])vpv([^a-z]|$)' then 'VPV'
    when x ~* '(^|[^a-z])vrk([^a-z]|$)' then 'VRK'
    when x ~* '(^|[^a-z])inter versicherung' then 'INTER'
    when x ~* '(^|[^a-z])wwk([^a-z]|$)' then 'WWK'
    when x ~* 'volkswohl' then 'Volkswohl Bund'
    when x ~* '((^|[^a-z])alh([^a-z]|$)|alte leipziger|hallesche)' then 'ALH Gruppe'
    when x ~* 'münchener verein|muenchener verein' then 'Münchener Verein'
    when x ~* '(^|[^a-z])vgh([^a-z]|$)' then 'VGH'
    when x ~* '(^|[^a-z])sdk([^a-z]|$)|süddeutsche kranken' then 'SDK'
    else null end
    from (select lower(coalesce(p_name, '') || ' ' || coalesce(p_hinweis, '')) as x) s
$$;

update core.companies co set gruppe = core.firmengruppe_erkennen(co.name,
         (select string_agg(p.benutzername, ' ') from core.instagram_personen p where p.company_id = co.company_id))
 where not co.gruppe_manuell;
