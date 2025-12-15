BEGIN;

-- Permission scopes and role mapping
CREATE TABLE IF NOT EXISTS permission_scopes (
    code        TEXT PRIMARY KEY,
    description TEXT
);

CREATE TABLE IF NOT EXISTS role_permissions (
    role_id    INTEGER REFERENCES roles(id) ON DELETE CASCADE,
    scope_code TEXT REFERENCES permission_scopes(code) ON DELETE CASCADE,
    PRIMARY KEY (role_id, scope_code)
);

INSERT INTO permission_scopes (code, description) VALUES
  ('VIEW_PRODUCTS', 'Xem danh mục sản phẩm'),
  ('EDIT_PRODUCTS', 'Chỉnh sửa sản phẩm'),
  ('VIEW_ORDERS', 'Xem đơn hàng'),
  ('EDIT_ORDERS', 'Chỉnh sửa đơn hàng'),
  ('VIEW_INVENTORY', 'Xem tồn kho'),
  ('EDIT_INVENTORY', 'Cập nhật tồn kho'),
  ('VIEW_FINANCE', 'Xem thanh toán'),
  ('MANAGE_USERS', 'Quản lý tài khoản người dùng')
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permissions (role_id, scope_code) VALUES
  (1, 'VIEW_PRODUCTS'), (1, 'EDIT_PRODUCTS'), (1, 'VIEW_ORDERS'), (1, 'EDIT_ORDERS'),
  (1, 'VIEW_INVENTORY'), (1, 'EDIT_INVENTORY'), (1, 'VIEW_FINANCE'), (1, 'MANAGE_USERS'),
  (2, 'VIEW_PRODUCTS'), (2, 'VIEW_ORDERS'), (2, 'EDIT_ORDERS'), (2, 'VIEW_INVENTORY'),
  (3, 'VIEW_PRODUCTS'), (3, 'VIEW_INVENTORY'),
  (4, 'VIEW_PRODUCTS')
ON CONFLICT DO NOTHING;

-- User sessions (auth tokens)
CREATE TABLE IF NOT EXISTS user_sessions (
    id             BIGSERIAL PRIMARY KEY,
    user_id        INTEGER NOT NULL REFERENCES user_accounts(id) ON DELETE CASCADE,
    session_token  TEXT NOT NULL UNIQUE,
    expires_at     TIMESTAMP,
    created_at     TIMESTAMP NOT NULL DEFAULT NOW(),
    revoked_at     TIMESTAMP
);

-- Customer addresses
CREATE TABLE IF NOT EXISTS customer_addresses (
    id         SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    label      VARCHAR(100),
    address    TEXT NOT NULL,
    city       VARCHAR(100),
    district   VARCHAR(100),
    phone      VARCHAR(30),
    is_default BOOLEAN NOT NULL DEFAULT FALSE
);

ALTER TABLE sales_orders ADD COLUMN IF NOT EXISTS shipping_address_id INTEGER;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_sales_shipping_address'
  ) THEN
    ALTER TABLE sales_orders
      ADD CONSTRAINT fk_sales_shipping_address
      FOREIGN KEY (shipping_address_id) REFERENCES customer_addresses(id);
  END IF;
END$$;

-- Shipment detail extensions
ALTER TABLE shipments ADD COLUMN IF NOT EXISTS recipient_name  VARCHAR(150);
ALTER TABLE shipments ADD COLUMN IF NOT EXISTS recipient_phone VARCHAR(30);
ALTER TABLE shipments ADD COLUMN IF NOT EXISTS destination_address TEXT;
ALTER TABLE shipments ADD COLUMN IF NOT EXISTS notes TEXT;

-- Payment transaction log
CREATE TABLE IF NOT EXISTS payment_transactions (
    id           SERIAL PRIMARY KEY,
    payment_id   INTEGER NOT NULL REFERENCES payments(id) ON DELETE CASCADE,
    status       VARCHAR(50) NOT NULL,
    gateway      VARCHAR(100),
    transaction_ref VARCHAR(150),
    amount       NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    created_at   TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Loyalty program
CREATE TABLE IF NOT EXISTS loyalty_accounts (
    id           SERIAL PRIMARY KEY,
    customer_id  INTEGER NOT NULL UNIQUE REFERENCES customers(id) ON DELETE CASCADE,
    points       INTEGER NOT NULL DEFAULT 0 CHECK (points >= 0),
    tier         VARCHAR(50) DEFAULT 'Silver'
);

CREATE TABLE IF NOT EXISTS loyalty_transactions (
    id              SERIAL PRIMARY KEY,
    loyalty_id      INTEGER NOT NULL REFERENCES loyalty_accounts(id) ON DELETE CASCADE,
    change_type     VARCHAR(50) NOT NULL, -- EARN/REDEEM/ADJUST
    points_change   INTEGER NOT NULL,
    reference       TEXT,
    created_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Stock adjustments (manual audit)
CREATE TABLE IF NOT EXISTS stock_adjustments (
    id           SERIAL PRIMARY KEY,
    warehouse_id INTEGER REFERENCES warehouses(id),
    staff_id     INTEGER REFERENCES staffs(id),
    reason       TEXT,
    created_at   TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS stock_adjustment_lines (
    id              SERIAL PRIMARY KEY,
    adjustment_id   INTEGER NOT NULL REFERENCES stock_adjustments(id) ON DELETE CASCADE,
    product_code    VARCHAR(50) NOT NULL REFERENCES products(product_code),
    quantity_change INTEGER NOT NULL,
    note            TEXT
);

-- Warehouse transfers
CREATE TABLE IF NOT EXISTS stock_transfers (
    id                 SERIAL PRIMARY KEY,
    from_warehouse_id  INTEGER REFERENCES warehouses(id),
    to_warehouse_id    INTEGER REFERENCES warehouses(id),
    staff_id           INTEGER REFERENCES staffs(id),
    status             VARCHAR(50) NOT NULL DEFAULT 'In Transit',
    created_at         TIMESTAMP NOT NULL DEFAULT NOW(),
    delivered_at       TIMESTAMP
);

CREATE TABLE IF NOT EXISTS stock_transfer_lines (
    id           SERIAL PRIMARY KEY,
    transfer_id  INTEGER NOT NULL REFERENCES stock_transfers(id) ON DELETE CASCADE,
    imei         VARCHAR(50) NOT NULL REFERENCES inventory_items(imei)
);

-- Repair / warranty service orders
CREATE TABLE IF NOT EXISTS service_orders (
    id            SERIAL PRIMARY KEY,
    imei          VARCHAR(50) NOT NULL REFERENCES inventory_items(imei),
    order_id      INTEGER REFERENCES sales_orders(id),
    status        VARCHAR(50) NOT NULL DEFAULT 'Received', -- Received / In Progress / Completed / Returned
    issue_note    TEXT,
    resolution    TEXT,
    labor_cost    NUMERIC(12,2) CHECK (labor_cost IS NULL OR labor_cost >= 0),
    parts_cost    NUMERIC(12,2) CHECK (parts_cost IS NULL OR parts_cost >= 0),
    created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMP
);

-- Seed data for new structures
INSERT INTO customer_addresses (id, customer_id, label, address, city, district, phone, is_default) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'Home', '123 Nguyen Trai, Q1', 'HCMC', 'District 1', '0912000001', TRUE),
  (2, 2, 'Office', '45 Le Loi, Q1', 'HCMC', 'District 1', '0912000002', TRUE),
  (3, 3, 'Home', '89 Cau Giay', 'Hanoi', 'Cau Giay', '0912000003', TRUE)
ON CONFLICT (id) DO NOTHING;

UPDATE sales_orders SET shipping_address_id = 1 WHERE id = 1 AND shipping_address_id IS NULL;
UPDATE sales_orders SET shipping_address_id = 2 WHERE id = 2 AND shipping_address_id IS NULL;
UPDATE sales_orders SET shipping_address_id = 3 WHERE id = 3 AND shipping_address_id IS NULL;

UPDATE shipments s
SET recipient_name = COALESCE(s.recipient_name, c.name),
    recipient_phone = COALESCE(s.recipient_phone, c.phone),
    destination_address = COALESCE(s.destination_address, ca.address)
FROM sales_orders so
JOIN customers c ON c.id = so.customer_id
LEFT JOIN customer_addresses ca ON ca.id = so.shipping_address_id
WHERE s.order_id = so.id;

INSERT INTO payment_transactions (id, payment_id, status, gateway, transaction_ref, amount, created_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'SUCCESS', 'CashDesk', 'CASH-0001', 9175.10, NOW() - INTERVAL '13 days'),
  (2, 2, 'PENDING', 'CardPOS',  'CARD-0002', 10000.00, NOW() - INTERVAL '9 days'),
  (3, 3, 'SUCCESS', 'Bank',     'TRANSFER-0003', 8028.90, NOW() - INTERVAL '2 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO loyalty_accounts (id, customer_id, points, tier) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 120, 'Silver'),
  (2, 2, 300, 'Gold'),
  (3, 3, 80,  'Silver')
ON CONFLICT (customer_id) DO NOTHING;

INSERT INTO loyalty_transactions (id, loyalty_id, change_type, points_change, reference, created_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'EARN', 100, 'Order 1', NOW() - INTERVAL '13 days'),
  (2, 2, 'EARN', 300, 'Order 2', NOW() - INTERVAL '9 days'),
  (3, 3, 'EARN', 80,  'Order 3', NOW() - INTERVAL '2 days'),
  (4, 2, 'REDEEM', -50, 'Voucher', NOW() - INTERVAL '1 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO stock_adjustments (id, warehouse_id, staff_id, reason, created_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 1, 'Cycle count correction', NOW() - INTERVAL '7 days'),
  (2, 1, 2, 'Damage write-off', NOW() - INTERVAL '4 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO stock_adjustment_lines (id, adjustment_id, product_code, quantity_change, note) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'P-c80d21bcd746e73b0b178ea29997ec56', 1, 'Found extra unit'),
  (2, 2, 'P-35c5799616b634ed41a5d5790787894f', -1, 'Damaged screen')
ON CONFLICT (id) DO NOTHING;

INSERT INTO stock_transfers (id, from_warehouse_id, to_warehouse_id, staff_id, status, created_at, delivered_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 2, 2, 'Delivered', NOW() - INTERVAL '6 days', NOW() - INTERVAL '5 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO stock_transfer_lines (id, transfer_id, imei) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, '359876000000006')
ON CONFLICT (id) DO NOTHING;

-- Reflect transfer in inventory warehouse
UPDATE inventory_items SET warehouse_id = 2 WHERE imei = '359876000000006';

INSERT INTO service_orders (id, imei, order_id, status, issue_note, resolution, labor_cost, parts_cost, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES
  (1, '359876000000003', 2, 'Completed', 'Battery issue', 'Replaced battery', 150000, 200000, NOW() - INTERVAL '5 days', NOW() - INTERVAL '4 days'),
  (2, '359876000000004', 3, 'In Progress', 'Screen flicker', NULL, 0, 0, NOW() - INTERVAL '2 days', NULL)
ON CONFLICT (id) DO NOTHING;

-- Sample user sessions
INSERT INTO user_sessions (id, user_id, session_token, expires_at, created_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'sess-admin-001', NOW() + INTERVAL '7 days', NOW() - INTERVAL '1 days'),
  (2, 2, 'sess-sales-002', NOW() + INTERVAL '5 days', NOW() - INTERVAL '1 days'),
  (3, 3, 'sess-tech-003',  NOW() + INTERVAL '3 days', NOW() - INTERVAL '1 days')
ON CONFLICT (id) DO NOTHING;

-- Set sequences for new serial tables
SELECT setval(pg_get_serial_sequence('customer_addresses', 'id'), COALESCE((SELECT MAX(id) FROM customer_addresses), 0), true);
SELECT setval(pg_get_serial_sequence('payment_transactions', 'id'), COALESCE((SELECT MAX(id) FROM payment_transactions), 0), true);
SELECT setval(pg_get_serial_sequence('loyalty_accounts', 'id'), COALESCE((SELECT MAX(id) FROM loyalty_accounts), 0), true);
SELECT setval(pg_get_serial_sequence('loyalty_transactions', 'id'), COALESCE((SELECT MAX(id) FROM loyalty_transactions), 0), true);
SELECT setval(pg_get_serial_sequence('stock_adjustments', 'id'), COALESCE((SELECT MAX(id) FROM stock_adjustments), 0), true);
SELECT setval(pg_get_serial_sequence('stock_adjustment_lines', 'id'), COALESCE((SELECT MAX(id) FROM stock_adjustment_lines), 0), true);
SELECT setval(pg_get_serial_sequence('stock_transfers', 'id'), COALESCE((SELECT MAX(id) FROM stock_transfers), 0), true);
SELECT setval(pg_get_serial_sequence('stock_transfer_lines', 'id'), COALESCE((SELECT MAX(id) FROM stock_transfer_lines), 0), true);
SELECT setval(pg_get_serial_sequence('service_orders', 'id'), COALESCE((SELECT MAX(id) FROM service_orders), 0), true);
SELECT setval(pg_get_serial_sequence('permission_scopes', 'code'), 1, true);
SELECT setval(pg_get_serial_sequence('user_sessions', 'id'), COALESCE((SELECT MAX(id) FROM user_sessions), 0), true);

COMMIT;
