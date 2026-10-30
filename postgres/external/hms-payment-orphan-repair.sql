-- Repair stuck Collect Payment: orphan Payment row + Payment sequence out of sync.
-- Symptom: duplicate key on payment_id (often payment_id equals a prior retry, e.g. 10001).
--
-- Inspect first:
--   SELECT payment_id, status_id, amount, payment_ref_num, comments FROM payment
--     WHERE payment_id = '10001' OR comments LIKE '%appointment 10001%';
--   SELECT * FROM payment_application WHERE payment_id = '10001';
--   SELECT seq_name, seq_id FROM sequence_value_item WHERE seq_name = 'Payment';
--
-- Safe delete only when payment is unapplied orphan (adjust payment_id / appointment in WHERE):
/*
DELETE FROM payment
 WHERE payment_id = '10001'
   AND status_id = 'PMNT_NOT_PAID'
   AND NOT EXISTS (SELECT 1 FROM payment_application pa WHERE pa.payment_id = payment.payment_id);
*/

\echo '--- Payment sequence repair (numeric payment_id only) ---'
UPDATE sequence_value_item s
   SET seq_id = GREATEST(
       COALESCE(s.seq_id, 0),
       COALESCE((
           SELECT MAX(CAST(p.payment_id AS BIGINT))
             FROM payment p
            WHERE p.payment_id ~ '^[0-9]+$'
       ), 0) + 1
   )
 WHERE s.seq_name = 'Payment';

SELECT seq_name, seq_id FROM sequence_value_item WHERE seq_name = 'Payment';
