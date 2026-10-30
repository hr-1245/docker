-- Minimal OFBiz accounting setup for Collect Payment / sales invoice GL posting.
-- Use when GlAccountDemoData + HmsCoaSeedData were loaded but AccountingDemoData.xml was not.
--
-- Run on hms_db:
--   psql -h localhost -U postgres -d hms_db -f docker/postgres/external/hms-accounting-demo-minimum-hotfix.sql
-- Then re-run commissions hotfix so COMMISSIONS_PAYABLE stays on HMS leaf 210002:
--   psql ... -f docker/postgres/external/hms-commissions-payable-hotfix.sql

\echo '--- Before ---'
SELECT COUNT(*) AS type_defaults_company FROM gl_account_type_default WHERE organization_party_id = 'Company';
SELECT COUNT(*) AS org_links_company FROM gl_account_organization WHERE organization_party_id = 'Company';
SELECT COUNT(*) AS open_fiscal_periods_now FROM custom_time_period
 WHERE organization_party_id = 'Company' AND is_closed = 'N'
   AND from_date <= NOW() AND thru_date > NOW();

-- Suspense journal + org accounting preference (OFBiz demo "Company" setup)
INSERT INTO gl_journal (gl_journal_id, organization_party_id, gl_journal_name)
SELECT 'ERROR_JOURNAL', 'Company', 'Suspense transactions'
WHERE NOT EXISTS (SELECT 1 FROM gl_journal WHERE gl_journal_id = 'ERROR_JOURNAL');

INSERT INTO party_acctg_preference (
    party_id, tax_form_id, cogs_method_id, base_currency_uom_id,
    invoice_seq_cust_meth_id, invoice_id_prefix, quote_id_prefix, order_id_prefix, error_gl_journal_id
)
SELECT 'Company', 'US_IRS_1120', 'COGS_LIFO', 'USD',
       'INV_HOOK_ENF_SEQ', 'CI', 'CQ', 'CO', 'ERROR_JOURNAL'
WHERE NOT EXISTS (SELECT 1 FROM party_acctg_preference WHERE party_id = 'Company');

-- Org links required for posting (demo chart accounts)
INSERT INTO gl_account_organization (gl_account_id, organization_party_id, from_date)
SELECT v.gl_account_id, 'Company', TIMESTAMP '2001-01-01 00:00:00'
FROM (VALUES
    ('112000'), ('120000'), ('126000'), ('210000'), ('221100'),
    ('400000'), ('401000'), ('500000'), ('336000'), ('850000'), ('900000')
) AS v(gl_account_id)
INNER JOIN gl_account ga ON ga.gl_account_id = v.gl_account_id
WHERE NOT EXISTS (
    SELECT 1 FROM gl_account_organization gao
    WHERE gao.gl_account_id = v.gl_account_id AND gao.organization_party_id = 'Company'
);

-- Standard demo GlAccountTypeDefault rows (COMMISSIONS_PAYABLE handled by commissions hotfix)
INSERT INTO gl_account_type_default (gl_account_type_id, organization_party_id, gl_account_id)
SELECT v.gl_account_type_id, 'Company', v.gl_account_id
FROM (VALUES
    ('ACCOUNTS_RECEIVABLE', '120000'),
    ('ACCREC_UNAPPLIED', '126000'),
    ('INTRSTINC_RECEIVABLE', '121800'),
    ('INVENTORY_XFER_OUT', '125000'),
    ('INVENTORY_ACCOUNT', '140000'),
    ('RAWMAT_INVENTORY', '141000'),
    ('WIP_INVENTORY', '142000'),
    ('PREPAID_EXPENSES', '150000'),
    ('ACCOUNTS_PAYABLE', '210000'),
    ('CUSTOMER_CREDIT', '213000'),
    ('CUSTOMER_DEPOSIT', '213300'),
    ('UNINVOICED_SHIP_RCPT', '214000'),
    ('INVENTORY_XFER_IN', '215000'),
    ('ACCPAYABLE_UNAPPLIED', '216000'),
    ('RETAINED_EARNINGS', '336000'),
    ('SALES_ACCOUNT', '400000'),
    ('COGS_ACCOUNT', '500000'),
    ('INV_ADJ_VAL', '515000'),
    ('FX_GAIN_LOSS_ACCT', '518000'),
    ('OPERATING_EXPENSE', '600000'),
    ('PROFIT_LOSS_ACCOUNT', '850000'),
    ('TAX_ACCOUNT', '900000')
) AS v(gl_account_type_id, gl_account_id)
INNER JOIN gl_account ga ON ga.gl_account_id = v.gl_account_id
WHERE NOT EXISTS (
    SELECT 1 FROM gl_account_type_default d
    WHERE d.gl_account_type_id = v.gl_account_type_id AND d.organization_party_id = 'Company'
);

INSERT INTO payment_gl_account_type_map (payment_type_id, gl_account_type_id, organization_party_id)
SELECT v.payment_type_id, v.gl_account_type_id, 'Company'
FROM (VALUES
    ('CUSTOMER_PAYMENT', 'ACCREC_UNAPPLIED'),
    ('CUSTOMER_DEPOSIT', 'CUSTOMER_DEPOSIT'),
    ('COMMISSION_PAYMENT', 'COMMISSIONS_PAYABLE')
) AS v(payment_type_id, gl_account_type_id)
WHERE NOT EXISTS (
    SELECT 1 FROM payment_gl_account_type_map m
    WHERE m.organization_party_id = 'Company'
      AND m.payment_type_id = v.payment_type_id
      AND m.gl_account_type_id = v.gl_account_type_id
);

INSERT INTO payment_method_type_gl_account (payment_method_type_id, organization_party_id, gl_account_id)
SELECT 'CASH', 'Company', '112000'
WHERE EXISTS (SELECT 1 FROM gl_account WHERE gl_account_id = '112000')
  AND NOT EXISTS (
    SELECT 1 FROM payment_method_type_gl_account
    WHERE organization_party_id = 'Company' AND payment_method_type_id = 'CASH'
);

UPDATE invoice_item_type
   SET default_gl_account_id = '401000'
 WHERE invoice_item_type_id = 'INV_SPROD_ITEM'
   AND (default_gl_account_id IS NULL OR TRIM(default_gl_account_id) = '')
   AND EXISTS (SELECT 1 FROM gl_account WHERE gl_account_id = '401000');

-- Fiscal year covering Oct 2026 (demo id 6600)
INSERT INTO custom_time_period (
    custom_time_period_id, organization_party_id, period_type_id,
    from_date, thru_date, is_closed, period_num, period_name
)
SELECT '6600', 'Company', 'FISCAL_YEAR',
       TIMESTAMP '2026-01-01 00:00:00', TIMESTAMP '2027-01-01 00:00:00', 'N', 18, 'FY2026'
WHERE NOT EXISTS (SELECT 1 FROM custom_time_period WHERE custom_time_period_id = '6600');

\echo '--- After (expect type_defaults >= 20, open_fiscal_periods >= 1) ---'
SELECT COUNT(*) AS type_defaults_company FROM gl_account_type_default WHERE organization_party_id = 'Company';
SELECT gl_account_type_id, gl_account_id FROM gl_account_type_default
 WHERE organization_party_id = 'Company' ORDER BY gl_account_type_id;
SELECT COUNT(*) AS open_fiscal_periods_now FROM custom_time_period
 WHERE organization_party_id = 'Company' AND is_closed = 'N'
   AND from_date <= NOW() AND thru_date > NOW();
SELECT payment_method_type_id, gl_account_id FROM payment_method_type_gl_account
 WHERE organization_party_id = 'Company' AND payment_method_type_id = 'CASH';
