BEGIN;

-- Clean up redundant overload
DROP FUNCTION IF EXISTS fn_calculatediscountvalue(integer, integer);

-- User accounts for login (one account per staff)
CREATE TABLE IF NOT EXISTS user_accounts (
    id             SERIAL PRIMARY KEY,
    staff_id       INTEGER REFERENCES staffs(id) ON DELETE SET NULL,
    username       VARCHAR(100) NOT NULL UNIQUE,
    password_hash  TEXT NOT NULL,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    last_login     TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_accounts_staff ON user_accounts(staff_id);

-- Warehouses / locations
CREATE TABLE IF NOT EXISTS warehouses (
    id       SERIAL PRIMARY KEY,
    name     VARCHAR(150) NOT NULL UNIQUE,
    address  TEXT,
    active   BOOLEAN NOT NULL DEFAULT TRUE
);

-- Seed warehouses early so FK add passes
INSERT INTO warehouses (id, name, address, active) OVERRIDING SYSTEM VALUE VALUES
  (1, 'Main Warehouse', 'Ho Chi Minh', TRUE),
  (2, 'Hanoi Branch', 'Hanoi', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Ensure inventory items track warehouse
ALTER TABLE inventory_items ADD COLUMN IF NOT EXISTS warehouse_id INTEGER;
UPDATE inventory_items SET warehouse_id = COALESCE(warehouse_id, 1);
ALTER TABLE inventory_items ALTER COLUMN warehouse_id SET NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_inventory_warehouse'
  ) THEN
    ALTER TABLE inventory_items
      ADD CONSTRAINT fk_inventory_warehouse
      FOREIGN KEY (warehouse_id) REFERENCES warehouses(id);
  END IF;
END$$;

-- Suppliers and purchasing
CREATE TABLE IF NOT EXISTS suppliers (
    id            SERIAL PRIMARY KEY,
    supplier_name VARCHAR(150) NOT NULL UNIQUE,
    contact_name  VARCHAR(150),
    phone         VARCHAR(50),
    email         VARCHAR(150)
);

CREATE TABLE IF NOT EXISTS purchase_orders (
    id          SERIAL PRIMARY KEY,
    supplier_id INTEGER NOT NULL REFERENCES suppliers(id),
    staff_id    INTEGER REFERENCES staffs(id),
    order_date  TIMESTAMP NOT NULL DEFAULT NOW(),
    status      VARCHAR(50) NOT NULL DEFAULT 'Pending',
    total_cost  NUMERIC(12,2) CHECK (total_cost IS NULL OR total_cost >= 0)
);

CREATE TABLE IF NOT EXISTS purchase_order_lines (
    id                SERIAL PRIMARY KEY,
    purchase_order_id INTEGER NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
    product_code      VARCHAR(50) NOT NULL REFERENCES products(product_code),
    quantity          INTEGER NOT NULL CHECK (quantity > 0),
    unit_cost         NUMERIC(12,2) NOT NULL CHECK (unit_cost >= 0)
);

-- Payments (support partial/multi payment)
CREATE TABLE IF NOT EXISTS payments (
    id                 SERIAL PRIMARY KEY,
    order_id           INTEGER NOT NULL REFERENCES sales_orders(id) ON DELETE CASCADE,
    payment_method_id  INTEGER REFERENCES lookup_payment_methods(id),
    amount             NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    status             VARCHAR(50) NOT NULL DEFAULT 'PAID', -- PAID / PARTIAL / PENDING / REFUNDED
    transaction_ref    VARCHAR(150),
    paid_at            TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Shipments / deliveries
CREATE TABLE IF NOT EXISTS shipments (
    id               SERIAL PRIMARY KEY,
    order_id         INTEGER NOT NULL REFERENCES sales_orders(id) ON DELETE CASCADE,
    carrier          VARCHAR(100),
    tracking_number  VARCHAR(100) UNIQUE,
    status           VARCHAR(50) NOT NULL DEFAULT 'Shipped', -- Shipped / Delivered / Cancelled
    shipping_fee     NUMERIC(12,2) CHECK (shipping_fee IS NULL OR shipping_fee >= 0),
    shipped_at       TIMESTAMP,
    delivered_at     TIMESTAMP
);

-- Stock movement log
CREATE TABLE IF NOT EXISTS stock_movements (
    id              BIGSERIAL PRIMARY KEY,
    imei            VARCHAR(50) NOT NULL REFERENCES inventory_items(imei),
    from_status_id  INTEGER REFERENCES lookup_stock_statuses(id),
    to_status_id    INTEGER REFERENCES lookup_stock_statuses(id),
    reason          TEXT,
    moved_at        TIMESTAMP NOT NULL DEFAULT NOW(),
    staff_id        INTEGER REFERENCES staffs(id)
);

-- Refunds linked to returns and payments
CREATE TABLE IF NOT EXISTS refunds (
    id             SERIAL PRIMARY KEY,
    return_id      INTEGER NOT NULL REFERENCES return_records(id) ON DELETE CASCADE,
    payment_id     INTEGER REFERENCES payments(id),
    amount         NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    refund_method  VARCHAR(100),
    status         VARCHAR(50) NOT NULL DEFAULT 'Processed', -- Processed / Pending / Rejected
    refunded_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Seed data for new structures (idempotent)
INSERT INTO user_accounts (id, staff_id, username, password_hash, is_active, last_login) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'admin', '$2b$10$exampleadminhash', TRUE, NOW() - INTERVAL '1 day'),
  (2, 2, 'sales', '$2b$10$examplesaleshash', TRUE, NOW() - INTERVAL '2 days'),
  (3, 3, 'tech',  '$2b$10$exampletechhash', TRUE, NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO suppliers (id, supplier_name, contact_name, phone, email) OVERRIDING SYSTEM VALUE VALUES
  (1, 'VietMobile Supply', 'Mr. An', '0909000001', 'an@vietmobile.vn'),
  (2, 'SaiGon Gadgets',   'Ms. Hoa', '0909000002', 'hoa@saigongadgets.vn')
ON CONFLICT (id) DO NOTHING;

INSERT INTO purchase_orders (id, supplier_id, staff_id, order_date, status, total_cost) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 1, NOW() - INTERVAL '20 days', 'Received', 45000.00),
  (2, 2, 3, NOW() - INTERVAL '12 days', 'Received', 30000.00)
ON CONFLICT (id) DO NOTHING;

INSERT INTO purchase_order_lines (id, purchase_order_id, product_code, quantity, unit_cost) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'P-c80d21bcd746e73b0b178ea29997ec56', 10, 3000.00),
  (2, 1, 'P-35c5799616b634ed41a5d5790787894f',  8, 12000.00),
  (3, 2, 'P-870c379032773bf65d8d93ac96105ae2',  5, 15000.00),
  (4, 2, 'P-f7b4318dd94d7781ab782abec6655919', 12, 6000.00)
ON CONFLICT (id) DO NOTHING;

INSERT INTO payments (id, order_id, payment_method_id, amount, status, transaction_ref, paid_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 1, 9175.10, 'PAID',    'CASH-0001', NOW() - INTERVAL '13 days'),
  (2, 2, 2, 10000.00,'PARTIAL', 'CARD-0002', NOW() - INTERVAL '9 days'),
  (3, 3, 3, 8028.90, 'PAID',    'TRANSFER-0003', NOW() - INTERVAL '2 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO shipments (id, order_id, carrier, tracking_number, status, shipping_fee, shipped_at, delivered_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'VNPost',  'VNPOST-001', 'Delivered', 30000, NOW() - INTERVAL '13 days', NOW() - INTERVAL '11 days'),
  (2, 2, 'GHN',     'GHN-002',    'Shipped',   25000, NOW() - INTERVAL '8 days',  NULL),
  (3, 3, 'GHTK',    'GHTK-003',   'Delivered', 20000, NOW() - INTERVAL '2 days',  NOW() - INTERVAL '1 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO stock_movements (id, imei, from_status_id, to_status_id, reason, moved_at, staff_id) VALUES
  (1, '359876000000001', NULL, 3, 'Sold with order 1', NOW() - INTERVAL '13 days', 1),
  (2, '359876000000002', NULL, 3, 'Sold with order 1', NOW() - INTERVAL '13 days', 1),
  (3, '359876000000003', NULL, 3, 'Sold with order 2', NOW() - INTERVAL '9 days',  2),
  (4, '359876000000003', 3,    4, 'Returned from order 2', NOW() - INTERVAL '5 days', 2),
  (5, '359876000000004', NULL, 3, 'Sold with order 3', NOW() - INTERVAL '2 days',  2)
ON CONFLICT (id) DO NOTHING;

INSERT INTO refunds (id, return_id, payment_id, amount, refund_method, status, refunded_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 2, 17999.00, 'Bank Transfer', 'Processed', NOW() - INTERVAL '4 days')
ON CONFLICT (id) DO NOTHING;

-- Minimal product specifications for seeded products
INSERT INTO product_specifications (product_code, spec_name, spec_value) VALUES
  ('P-c80d21bcd746e73b0b178ea29997ec56', 'Screen', '4.5 inch FWVGA'),
  ('P-c80d21bcd746e73b0b178ea29997ec56', 'Battery', '2000 mAh'),
  ('P-35c5799616b634ed41a5d5790787894f', 'Screen', '6.4 inch FHD+'),
  ('P-35c5799616b634ed41a5d5790787894f', 'Battery', '6000 mAh'),
  ('P-870c379032773bf65d8d93ac96105ae2', 'Screen', '5.0 inch FHD'),
  ('P-870c379032773bf65d8d93ac96105ae2', 'Battery', '3500 mAh'),
  ('P-f7b4318dd94d7781ab782abec6655919', 'Screen', '6.52 inch HD+'),
  ('P-f7b4318dd94d7781ab782abec6655919', 'Battery', '6000 mAh'),
  ('P-56a90d7d5dcba21767244ec97fa215e0', 'Screen', '6.4 inch HD+'),
  ('P-56a90d7d5dcba21767244ec97fa215e0', 'Battery', '5000 mAh')
ON CONFLICT DO NOTHING;

-- Align sequences for new tables
SELECT setval(pg_get_serial_sequence('warehouses', 'id'), COALESCE((SELECT MAX(id) FROM warehouses), 0), true);
SELECT setval(pg_get_serial_sequence('user_accounts', 'id'), COALESCE((SELECT MAX(id) FROM user_accounts), 0), true);
SELECT setval(pg_get_serial_sequence('suppliers', 'id'), COALESCE((SELECT MAX(id) FROM suppliers), 0), true);
SELECT setval(pg_get_serial_sequence('purchase_orders', 'id'), COALESCE((SELECT MAX(id) FROM purchase_orders), 0), true);
SELECT setval(pg_get_serial_sequence('purchase_order_lines', 'id'), COALESCE((SELECT MAX(id) FROM purchase_order_lines), 0), true);
SELECT setval(pg_get_serial_sequence('payments', 'id'), COALESCE((SELECT MAX(id) FROM payments), 0), true);
SELECT setval(pg_get_serial_sequence('shipments', 'id'), COALESCE((SELECT MAX(id) FROM shipments), 0), true);
SELECT setval(pg_get_serial_sequence('stock_movements', 'id'), COALESCE((SELECT MAX(id) FROM stock_movements), 0), true);
SELECT setval(pg_get_serial_sequence('refunds', 'id'), COALESCE((SELECT MAX(id) FROM refunds), 0), true);

COMMIT;
