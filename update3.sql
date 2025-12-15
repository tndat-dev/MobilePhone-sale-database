BEGIN;

-- Enforce single default address per customer
CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_default_address
ON customer_addresses(customer_id)
WHERE is_default;

-- Add payment tracking fields to sales_orders
ALTER TABLE sales_orders ADD COLUMN IF NOT EXISTS paid_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0);
ALTER TABLE sales_orders ADD COLUMN IF NOT EXISTS payment_status VARCHAR(20) NOT NULL DEFAULT 'UNPAID';

-- Function to recalc paid amount and status from payments and refunds
CREATE OR REPLACE FUNCTION recalc_sales_order_payment(p_order_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_paid NUMERIC := 0;
    v_refunded NUMERIC := 0;
    v_total NUMERIC := 0;
    v_net NUMERIC := 0;
    v_status VARCHAR(20) := 'UNPAID';
BEGIN
    SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payments WHERE order_id = p_order_id;
    SELECT COALESCE(SUM(r.amount),0) INTO v_refunded
    FROM refunds r
    JOIN return_records rr ON rr.id = r.return_id
    WHERE rr.order_id = p_order_id;

    SELECT COALESCE(total_amount,0) INTO v_total FROM sales_orders WHERE id = p_order_id;

    v_net := GREATEST(v_paid - v_refunded, 0);

    IF v_net <= 0 THEN
        v_status := 'UNPAID';
    ELSIF v_net + 0.009 >= v_total THEN
        v_status := 'PAID';
    ELSE
        v_status := 'PARTIAL';
    END IF;

    UPDATE sales_orders
    SET paid_amount = v_net,
        payment_status = v_status
    WHERE id = p_order_id;
END;
$$;

-- Trigger wrappers
CREATE OR REPLACE FUNCTION trg_payment_recalc()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM recalc_sales_order_payment(CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION trg_refund_recalc()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_id INT;
BEGIN
    SELECT rr.order_id INTO v_order_id FROM return_records rr WHERE rr.id = CASE WHEN TG_OP = 'DELETE' THEN OLD.return_id ELSE NEW.return_id END;
    IF v_order_id IS NOT NULL THEN
        PERFORM recalc_sales_order_payment(v_order_id);
    END IF;
    RETURN NULL;
END;
$$;

-- Attach triggers idempotently
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'payments_recalc_sales_order') THEN
    CREATE TRIGGER payments_recalc_sales_order
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION trg_payment_recalc();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'refunds_recalc_sales_order') THEN
    CREATE TRIGGER refunds_recalc_sales_order
    AFTER INSERT OR UPDATE OR DELETE ON refunds
    FOR EACH ROW EXECUTE FUNCTION trg_refund_recalc();
  END IF;
END$$;

-- Recompute existing orders
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id FROM sales_orders LOOP
        PERFORM recalc_sales_order_payment(r.id);
    END LOOP;
END;
$$;

COMMIT;
