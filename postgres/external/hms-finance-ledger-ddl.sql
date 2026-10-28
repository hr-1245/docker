-- HMS finance ledger (HmsFinanceEntry / HmsFinanceAudit). Run as PostgreSQL superuser or schema owner.
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS public.hms_finance_entry (
    finance_entry_id VARCHAR(20) NOT NULL,
    source_key VARCHAR(255),
    entry_kind VARCHAR(20),
    origin VARCHAR(20),
    source_type VARCHAR(20),
    source_id VARCHAR(20),
    source_parent_id VARCHAR(20),
    entry_date DATE,
    category VARCHAR(100),
    sub_category VARCHAR(100),
    reference_no VARCHAR(60),
    description TEXT,
    amount NUMERIC(18, 2),
    doctor_party_id VARCHAR(20),
    doctor_name VARCHAR(100),
    department VARCHAR(100),
    gross_amount NUMERIC(18, 2),
    share_pct DOUBLE PRECISION,
    share_amount NUMERIC(18, 2),
    status_id VARCHAR(20),
    share_adjusted CHAR(1),
    attachment_file_name VARCHAR(255),
    attachment_content_type VARCHAR(60),
    attachment_object_key VARCHAR(2000),
    created_by_user_login VARCHAR(255),
    created_stamp TIMESTAMPTZ,
    last_updated_by_user_login VARCHAR(255),
    last_updated_stamp TIMESTAMPTZ,
    last_updated_tx_stamp TIMESTAMPTZ,
    created_tx_stamp TIMESTAMPTZ,
    CONSTRAINT pk_hms_finance_entry PRIMARY KEY (finance_entry_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS hms_fin_src ON public.hms_finance_entry (source_key);
CREATE INDEX IF NOT EXISTS hms_fin_kind_dt ON public.hms_finance_entry (entry_kind, entry_date, status_id);
CREATE INDEX IF NOT EXISTS hms_fin_parent ON public.hms_finance_entry (source_parent_id, source_type);

CREATE TABLE IF NOT EXISTS public.hms_finance_audit (
    audit_id VARCHAR(20) NOT NULL,
    finance_entry_id VARCHAR(20),
    action_type VARCHAR(20),
    user_login_id VARCHAR(255),
    action_stamp TIMESTAMPTZ,
    previous_value TEXT,
    updated_value TEXT,
    detail TEXT,
    last_updated_stamp TIMESTAMPTZ,
    last_updated_tx_stamp TIMESTAMPTZ,
    created_stamp TIMESTAMPTZ,
    created_tx_stamp TIMESTAMPTZ,
    CONSTRAINT pk_hms_finance_audit PRIMARY KEY (audit_id)
);

CREATE INDEX IF NOT EXISTS hms_fin_aud ON public.hms_finance_audit (finance_entry_id, action_stamp);
CREATE INDEX IF NOT EXISTS hms_fin_aud_act ON public.hms_finance_audit (action_type, action_stamp);
