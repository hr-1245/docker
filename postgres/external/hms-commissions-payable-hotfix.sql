-- Idempotent hotfix for Collect Payment: COMMISSIONS_PAYABLE for organization Company.
-- Run on hms_db (same as DB_NAME / OFBIZ_POSTGRES_OFBIZ_DB):
--   psql -h localhost -U postgres -d hms_db -f docker/postgres/external/hms-commissions-payable-hotfix.sql
--
-- Requires at least one GL account: 210002 (HMS) or 221100 (demo) or any Company-linked COMMISSIONS_PAYABLE.

\echo '--- Before ---'
SELECT COUNT(*) AS gl_accounts FROM gl_account;
SELECT gl_account_id, gl_account_type_id FROM gl_account
 WHERE gl_account_id IN ('210002', '221100') OR gl_account_type_id = 'COMMISSIONS_PAYABLE';
SELECT * FROM gl_account_type_default
 WHERE gl_account_type_id = 'COMMISSIONS_PAYABLE' AND organization_party_id = 'Company';

INSERT INTO gl_account_type_default (gl_account_type_id, organization_party_id, gl_account_id)
SELECT 'COMMISSIONS_PAYABLE', 'Company', pick.gl_account_id
FROM (
    SELECT ga.gl_account_id,
           CASE ga.gl_account_id WHEN '210002' THEN 0 WHEN '221100' THEN 1 ELSE 2 END AS sort_key
    FROM gl_account ga
    INNER JOIN gl_account_organization gao
        ON gao.gl_account_id = ga.gl_account_id AND gao.organization_party_id = 'Company'
    WHERE ga.gl_account_id IN ('210002', '221100')
       OR ga.gl_account_type_id = 'COMMISSIONS_PAYABLE'
    ORDER BY sort_key
    LIMIT 1
) AS pick
WHERE NOT EXISTS (
    SELECT 1 FROM gl_account_type_default d
    WHERE d.gl_account_type_id = 'COMMISSIONS_PAYABLE'
      AND d.organization_party_id = 'Company'
);

\echo '--- After (need >=1 row) ---'
SELECT * FROM gl_account_type_default
 WHERE gl_account_type_id = 'COMMISSIONS_PAYABLE' AND organization_party_id = 'Company';

SELECT organization_party_id, gl_account_id FROM gl_account_organization
 WHERE organization_party_id = 'Company' AND gl_account_id IN ('210002', '221100');
