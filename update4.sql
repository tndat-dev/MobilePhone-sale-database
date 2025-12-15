BEGIN;

-- Harden auth seeds: update password hashes to real bcrypt samples (Password@123)
UPDATE user_accounts
SET password_hash = '$2b$10$u1NQfXB3d2J7BqXc9EwPceY1koRaSPoaqe7iH730cdpShUMHbOWgu'
WHERE id IN (1,2,3);

-- Refresh tokens (store hash only)
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES user_accounts(id) ON DELETE CASCADE,
    token_hash  TEXT NOT NULL UNIQUE,
    expires_at  TIMESTAMP NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT NOW(),
    revoked_at  TIMESTAMP
);

-- Session token hashing
ALTER TABLE user_sessions ADD COLUMN IF NOT EXISTS token_hash TEXT;
CREATE OR REPLACE FUNCTION set_session_token_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.token_hash IS NULL AND NEW.session_token IS NOT NULL THEN
        NEW.token_hash := md5(NEW.session_token);
    END IF;
    RETURN NEW;
END;
$$;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_user_session_hash') THEN
    CREATE TRIGGER trg_user_session_hash
    BEFORE INSERT OR UPDATE ON user_sessions
    FOR EACH ROW EXECUTE FUNCTION set_session_token_hash();
  END IF;
END$$;
UPDATE user_sessions SET token_hash = COALESCE(token_hash, md5(session_token));

-- Indexes to improve FK lookups
CREATE INDEX IF NOT EXISTS idx_payments_order ON payments(order_id);
CREATE INDEX IF NOT EXISTS idx_shipments_order ON shipments(order_id);
CREATE INDEX IF NOT EXISTS idx_inventory_product ON inventory_items(product_code);
CREATE INDEX IF NOT EXISTS idx_inventory_warehouse ON inventory_items(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_order_lines_order ON order_lines(order_id);
CREATE INDEX IF NOT EXISTS idx_order_lines_imei ON order_lines(imei);
CREATE INDEX IF NOT EXISTS idx_loyalty_tx_loyalty ON loyalty_transactions(loyalty_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_imei ON stock_movements(imei);
CREATE INDEX IF NOT EXISTS idx_stock_transfer_lines_transfer ON stock_transfer_lines(transfer_id);
CREATE INDEX IF NOT EXISTS idx_payment_transactions_payment ON payment_transactions(payment_id);

-- Shipment status hook: mark IMEIs sold when delivered
CREATE OR REPLACE FUNCTION trg_shipments_inventory_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_sold_id INT;
BEGIN
    SELECT id INTO v_sold_id FROM lookup_stock_statuses WHERE status_name = 'Sold';
    IF TG_OP IN ('INSERT','UPDATE') AND NEW.status = 'Delivered' THEN
        UPDATE inventory_items ii
        SET stock_status_id = v_sold_id
        FROM order_lines ol
        WHERE ol.order_id = NEW.order_id
          AND ii.imei = ol.imei
          AND (ii.stock_status_id IS DISTINCT FROM v_sold_id);
    END IF;
    RETURN NEW;
END;
$$;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'shipments_inventory_update') THEN
    CREATE TRIGGER shipments_inventory_update
    AFTER INSERT OR UPDATE OF status ON shipments
    FOR EACH ROW EXECUTE FUNCTION trg_shipments_inventory_update();
  END IF;
END$$;

-- Stock transfer hook: move IMEI warehouse and log movement when delivered
CREATE OR REPLACE FUNCTION trg_stock_transfer_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_from INT;
    v_to INT;
    v_staff INT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_from := NEW.from_warehouse_id;
        v_to := NEW.to_warehouse_id;
        v_staff := NEW.staff_id;
    ELSE
        v_from := NEW.from_warehouse_id;
        v_to := NEW.to_warehouse_id;
        v_staff := COALESCE(NEW.staff_id, OLD.staff_id);
    END IF;

    IF NEW.status = 'Delivered' THEN
        UPDATE inventory_items ii
        SET warehouse_id = v_to
        FROM stock_transfer_lines stl
        WHERE stl.transfer_id = NEW.id AND stl.imei = ii.imei
          AND ii.warehouse_id IS DISTINCT FROM v_to;

        INSERT INTO stock_movements (imei, from_status_id, to_status_id, reason, moved_at, staff_id)
        SELECT stl.imei, ii.stock_status_id, ii.stock_status_id, 'Transfer delivered', NOW(), v_staff
        FROM stock_transfer_lines stl
        JOIN inventory_items ii ON ii.imei = stl.imei
        WHERE stl.transfer_id = NEW.id
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'stock_transfers_apply') THEN
    CREATE TRIGGER stock_transfers_apply
    AFTER INSERT OR UPDATE OF status ON stock_transfers
    FOR EACH ROW EXECUTE FUNCTION trg_stock_transfer_apply();
  END IF;
END$$;

-- Loyalty earn/deduct based on payments/refunds
CREATE OR REPLACE FUNCTION ensure_loyalty_account(p_customer_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE v_id INT;
BEGIN
    SELECT id INTO v_id FROM loyalty_accounts WHERE customer_id = p_customer_id;
    IF v_id IS NULL THEN
        INSERT INTO loyalty_accounts(customer_id, points, tier) VALUES (p_customer_id, 0, 'Silver')
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION apply_loyalty_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer INT;
    v_loyalty_id INT;
    v_points INT;
    v_ref TEXT;
BEGIN
    SELECT customer_id INTO v_customer FROM sales_orders WHERE id = NEW.order_id;
    IF v_customer IS NULL THEN RETURN NULL; END IF;
    v_loyalty_id := ensure_loyalty_account(v_customer);
    v_points := FLOOR(NEW.amount / 10000);
    v_ref := 'PAYMENT:' || NEW.id;

    IF v_points <> 0 AND NOT EXISTS (SELECT 1 FROM loyalty_transactions WHERE reference = v_ref) THEN
        INSERT INTO loyalty_transactions(loyalty_id, change_type, points_change, reference) VALUES
            (v_loyalty_id, 'EARN', v_points, v_ref);
        UPDATE loyalty_accounts SET points = GREATEST(points + v_points, 0) WHERE id = v_loyalty_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION apply_loyalty_refund()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer INT;
    v_loyalty_id INT;
    v_points INT;
    v_ref TEXT;
BEGIN
    SELECT so.customer_id INTO v_customer
    FROM return_records rr
    JOIN sales_orders so ON so.id = rr.order_id
    WHERE rr.id = NEW.return_id;
    IF v_customer IS NULL THEN RETURN NULL; END IF;
    v_loyalty_id := ensure_loyalty_account(v_customer);
    v_points := -FLOOR(NEW.amount / 10000);
    v_ref := 'REFUND:' || NEW.id;

    IF v_points <> 0 AND NOT EXISTS (SELECT 1 FROM loyalty_transactions WHERE reference = v_ref) THEN
        INSERT INTO loyalty_transactions(loyalty_id, change_type, points_change, reference) VALUES
            (v_loyalty_id, 'REDEEM', v_points, v_ref);
        UPDATE loyalty_accounts SET points = GREATEST(points + v_points, 0) WHERE id = v_loyalty_id;
    END IF;
    RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'payments_loyalty') THEN
    CREATE TRIGGER payments_loyalty
    AFTER INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION apply_loyalty_payment();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'refunds_loyalty') THEN
    CREATE TRIGGER refunds_loyalty
    AFTER INSERT ON refunds
    FOR EACH ROW EXECUTE FUNCTION apply_loyalty_refund();
  END IF;
END$$;

-- Backfill loyalty based on existing payments
WITH pay AS (
  SELECT p.id AS payment_id,
         so.customer_id,
         FLOOR(p.amount / 10000) AS pts,
         'PAYMENT:' || p.id AS ref
  FROM payments p
  JOIN sales_orders so ON so.id = p.order_id
  WHERE FLOOR(p.amount / 10000) <> 0
    AND NOT EXISTS (SELECT 1 FROM loyalty_transactions lt WHERE lt.reference = 'PAYMENT:' || p.id)
),
ins_pay AS (
  INSERT INTO loyalty_transactions(loyalty_id, change_type, points_change, reference)
  SELECT ensure_loyalty_account(customer_id), 'EARN', pts, ref FROM pay
  RETURNING loyalty_id, points_change
)
UPDATE loyalty_accounts la
SET points = GREATEST(points + src.sum_pts, 0)
FROM (SELECT loyalty_id, SUM(points_change) AS sum_pts FROM ins_pay GROUP BY loyalty_id) src
WHERE la.id = src.loyalty_id;

-- Backfill loyalty based on existing refunds
WITH refd AS (
  SELECT r.id AS refund_id,
         so.customer_id,
         -FLOOR(r.amount / 10000) AS pts,
         'REFUND:' || r.id AS ref
  FROM refunds r
  JOIN return_records rr ON rr.id = r.return_id
  JOIN sales_orders so ON so.id = rr.order_id
  WHERE FLOOR(r.amount / 10000) <> 0
    AND NOT EXISTS (SELECT 1 FROM loyalty_transactions lt WHERE lt.reference = 'REFUND:' || r.id)
),
ins_ref AS (
  INSERT INTO loyalty_transactions(loyalty_id, change_type, points_change, reference)
  SELECT ensure_loyalty_account(customer_id), 'REDEEM', pts, ref FROM refd
  RETURNING loyalty_id, points_change
)
UPDATE loyalty_accounts la
SET points = GREATEST(points + src.sum_pts, 0)
FROM (SELECT loyalty_id, SUM(points_change) AS sum_pts FROM ins_ref GROUP BY loyalty_id) src
WHERE la.id = src.loyalty_id;

-- Reporting views
CREATE OR REPLACE VIEW v_revenue_summary AS
SELECT so.id AS order_id,
       so.total_amount,
       so.paid_amount,
       so.payment_status,
       so.order_date,
       c.name AS customer_name,
       s.name AS staff_name
FROM sales_orders so
LEFT JOIN customers c ON c.id = so.customer_id
LEFT JOIN staffs s ON s.id = so.staff_id;

CREATE OR REPLACE VIEW v_inventory_by_warehouse AS
SELECT w.id AS warehouse_id,
       w.name AS warehouse_name,
       ii.product_code,
       COUNT(*) AS item_count
FROM inventory_items ii
JOIN warehouses w ON w.id = ii.warehouse_id
GROUP BY w.id, w.name, ii.product_code;

COMMIT;
