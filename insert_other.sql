BEGIN;

-- Lookup tables
INSERT INTO lookup_order_statuses (id, status_name) OVERRIDING SYSTEM VALUE VALUES
  (1, 'Pending'),
  (2, 'Confirmed'),
  (3, 'Shipped'),
  (4, 'Completed'),
  (5, 'Cancelled')
ON CONFLICT (status_name) DO NOTHING;

INSERT INTO lookup_payment_methods (id, method_name) OVERRIDING SYSTEM VALUE VALUES
  (1, 'Cash'),
  (2, 'Credit Card'),
  (3, 'Bank Transfer'),
  (4, 'E-Wallet')
ON CONFLICT (id) DO NOTHING;

INSERT INTO lookup_stock_statuses (id, status_name) OVERRIDING SYSTEM VALUE VALUES
  (1, 'On Shelf'),
  (2, 'Reserved'),
  (3, 'Sold'),
  (4, 'Returned'),
  (5, 'Damaged')
ON CONFLICT (status_name) DO NOTHING;

-- Roles and staffs
INSERT INTO roles (id, role_name) OVERRIDING SYSTEM VALUE VALUES
  (1, 'Admin'),
  (2, 'Sales'),
  (3, 'Technician'),
  (4, 'Viewer')
ON CONFLICT DO NOTHING; -- no unique constraint on role_name, so ignore all conflicts

-- Minimal products required for FK to inventory/order lines
INSERT INTO products (product_code, brand, model_name, base_price, warranty_period) VALUES
  ('P-c80d21bcd746e73b0b178ea29997ec56', 'GIONEE', 'Pioneer P3S', 3990.00, 12),
  ('P-35c5799616b634ed41a5d5790787894f', 'SAMSUNG', 'Galaxy M30s', 14990.00, 12),
  ('P-870c379032773bf65d8d93ac96105ae2', 'Lenovo', 'Z2 Plus', 17999.00, 12),
  ('P-f7b4318dd94d7781ab782abec6655919', 'GIONEE', 'Max Pro', 7299.00, 12),
  ('P-56a90d7d5dcba21767244ec97fa215e0', 'SAMSUNG', 'Galaxy M11', 11745.00, 12)
ON CONFLICT (product_code) DO NOTHING; -- needed when running on fresh DB to avoid FK errors

INSERT INTO staffs (id, role_id, name, phone, email, created_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 'Nguyen Admin', '0901000001', 'admin@example.com', NOW() - INTERVAL '30 days'),
  (2, 2, 'Tran Sales',  '0901000002', 'sales@example.com', NOW() - INTERVAL '20 days'),
  (3, 3, 'Le Tech',    '0901000003', 'tech@example.com',  NOW() - INTERVAL '10 days')
ON CONFLICT (id) DO NOTHING;

-- Customers
INSERT INTO customers (id, name, phone, email, created_at) OVERRIDING SYSTEM VALUE VALUES
  (1, 'Pham Minh',   '0912000001', 'minh@example.com',   NOW() - INTERVAL '25 days'),
  (2, 'Hoang Lan',   '0912000002', 'lan@example.com',    NOW() - INTERVAL '15 days'),
  (3, 'Vu Thanh',    '0912000003', 'thanh@example.com',  NOW() - INTERVAL '5 days')
ON CONFLICT (id) DO NOTHING;

-- Tax rates and promotions
INSERT INTO tax_rates (id, tax_name, rate, start_date, end_date) OVERRIDING SYSTEM VALUE VALUES
  (1, 'VAT 10%', 10.00, '2023-01-01', NULL),
  (2, 'VAT 5%',   5.00, '2023-06-01', NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO promotions (id, promo_name, discount_percentage, start_date, end_date) OVERRIDING SYSTEM VALUE VALUES
  (1, 'New Year Sale', 5.00, '2024-01-01', '2024-01-31'),
  (2, 'Clearance',     8.00, '2024-02-01', '2024-02-28')
ON CONFLICT (id) DO NOTHING;

-- Inventory items (linked to existing product codes)
INSERT INTO inventory_items (imei, product_code, stock_status_id, receipt_date) VALUES
  ('359876000000001', 'P-c80d21bcd746e73b0b178ea29997ec56', 1, '2024-01-05'),
  ('359876000000002', 'P-35c5799616b634ed41a5d5790787894f', 1, '2024-01-07'),
  ('359876000000003', 'P-870c379032773bf65d8d93ac96105ae2', 1, '2024-01-09'),
  ('359876000000004', 'P-f7b4318dd94d7781ab782abec6655919', 1, '2024-01-12'),
  ('359876000000005', 'P-56a90d7d5dcba21767244ec97fa215e0', 1, '2024-01-15'),
  ('359876000000006', 'P-c80d21bcd746e73b0b178ea29997ec56', 1, '2024-01-18')
ON CONFLICT (imei) DO NOTHING;

-- Sales orders (totals recalculated by triggers after order line inserts)
INSERT INTO sales_orders (id, customer_id, staff_id, order_date, payment_method_id, order_status_id, tax_rate_id, promotion_id) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 1, NOW() - INTERVAL '14 days', 1, 4, 1, 1),
  (2, 2, 2, NOW() - INTERVAL '10 days', 2, 2, 2, NULL),
  (3, 3, 2, NOW() - INTERVAL '3 days',  3, 1, 1, NULL)
ON CONFLICT (id) DO NOTHING;

-- Order lines (must insert while inventory items are On Shelf)
INSERT INTO order_lines (order_id, imei, selling_price) VALUES
  (1, '359876000000001', 4290.00),
  (1, '359876000000002', 4490.00),
  (2, '359876000000003', 17999.00),
  (3, '359876000000004', 7299.00)
ON CONFLICT DO NOTHING;

-- Update inventory statuses to reflect sales/returns
UPDATE inventory_items SET stock_status_id = 3 WHERE imei IN ('359876000000001', '359876000000002', '359876000000003', '359876000000004');

-- Return record for one sold item
INSERT INTO return_records (id, order_id, imei, return_date, reason, refund_amount) OVERRIDING SYSTEM VALUE VALUES
  (1, 2, '359876000000003', CURRENT_DATE - INTERVAL '5 days', 'Customer changed mind', 17999.00)
ON CONFLICT (id) DO NOTHING;

-- Mark returned item accordingly
UPDATE inventory_items SET stock_status_id = 4 WHERE imei = '359876000000003';

-- Audit samples
INSERT INTO audit_logs (id, staff_id, operation_time, table_name, record_id, operation_type, details) OVERRIDING SYSTEM VALUE VALUES
  (1, 1, NOW() - INTERVAL '13 days', 'sales_orders', '1', 'INSERT', 'Seed order created'),
  (2, 2, NOW() - INTERVAL '9 days',  'sales_orders', '2', 'INSERT', 'Seed order created'),
  (3, 2, NOW() - INTERVAL '2 days',  'sales_orders', '3', 'INSERT', 'Seed order created')
ON CONFLICT (id) DO NOTHING;

INSERT INTO staff_audit_logs (id, action, staff_id, details, changed_at, changed_by) VALUES
  (1, 'CREATE', 1, '{"note":"Seed staff"}', NOW() - INTERVAL '30 days', CURRENT_USER),
  (2, 'CREATE', 2, '{"note":"Seed staff"}', NOW() - INTERVAL '20 days', CURRENT_USER),
  (3, 'CREATE', 3, '{"note":"Seed staff"}', NOW() - INTERVAL '10 days', CURRENT_USER)
ON CONFLICT (id) DO NOTHING;

-- Align sequences with seeded IDs
SELECT setval(pg_get_serial_sequence('lookup_order_statuses',  'id'), COALESCE((SELECT MAX(id) FROM lookup_order_statuses), 0), true);
SELECT setval(pg_get_serial_sequence('lookup_payment_methods', 'id'), COALESCE((SELECT MAX(id) FROM lookup_payment_methods), 0), true);
SELECT setval(pg_get_serial_sequence('lookup_stock_statuses',  'id'), COALESCE((SELECT MAX(id) FROM lookup_stock_statuses), 0), true);
SELECT setval(pg_get_serial_sequence('roles',                  'id'), COALESCE((SELECT MAX(id) FROM roles), 0), true);
SELECT setval(pg_get_serial_sequence('staffs',                 'id'), COALESCE((SELECT MAX(id) FROM staffs), 0), true);
SELECT setval(pg_get_serial_sequence('customers',              'id'), COALESCE((SELECT MAX(id) FROM customers), 0), true);
SELECT setval(pg_get_serial_sequence('tax_rates',              'id'), COALESCE((SELECT MAX(id) FROM tax_rates), 0), true);
SELECT setval(pg_get_serial_sequence('promotions',             'id'), COALESCE((SELECT MAX(id) FROM promotions), 0), true);
SELECT setval(pg_get_serial_sequence('sales_orders',           'id'), COALESCE((SELECT MAX(id) FROM sales_orders), 0), true);
SELECT setval(pg_get_serial_sequence('return_records',         'id'), COALESCE((SELECT MAX(id) FROM return_records), 0), true);
SELECT setval(pg_get_serial_sequence('audit_logs',             'id'), COALESCE((SELECT MAX(id) FROM audit_logs), 0), true);
SELECT setval(pg_get_serial_sequence('staff_audit_logs',       'id'), COALESCE((SELECT MAX(id) FROM staff_audit_logs), 0), true);

COMMIT;
