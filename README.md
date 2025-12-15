# Mobile Phone Shop Database

Tập hợp các script SQL để dựng và seed một hệ thống quản lý bán lẻ điện thoại di động.

## Thành phần chính
- **Catalog**: products, product_specifications (thông số), audit sản phẩm.
- **Kho**: inventory_items (IMEI), warehouses, stock_movements, stock_adjustments, stock_transfers, lookup_stock_statuses, trigger kiểm IMEI “On Shelf”.
- **Mua hàng**: suppliers, purchase_orders + lines.
- **Bán hàng**: sales_orders + order_lines (tính tổng, thuế/khuyến mãi), promotions, tax_rates, lookup_order_statuses.
- **Thanh toán & giao hàng**: payments + payment_transactions, shipments (carrier/tracking/fee/địa chỉ), payment_status/paid_amount trên đơn (trigger tính từ payments/refunds).
- **Trả hàng/hoàn tiền**: return_records + refunds (liên kết payment), trạng thái tồn kho cập nhật qua shipment/transfer.
- **Khách hàng & loyalty**: customers, customer_addresses (1 default/khách), loyalty_accounts + transactions.
- **Nhân sự & quyền**: staffs, roles, user_accounts, permission_scopes + role_permissions (RBAC seed), user_sessions, refresh_tokens, audit nhân sự.
- **Bảo hành/sửa chữa**: service_orders.
- **Báo cáo**: view v_revenue_summary, v_inventory_by_warehouse.


```
## Ghi chú bảo mật/hoàn thiện
- `password_hash` trong seed là bcrypt mẫu, cần thay bằng hash thực tế; session_token đang lưu thô kèm token_hash → cân nhắc chỉ lưu hash.
- RBAC mới dừng ở cấp bảng mapping, cần enforce ở ứng dụng hoặc RLS nếu cần.
- Logic shipment/transfer/loyalty ở mức cơ bản; có thể mở rộng workflow nhiều bước, voucher/coupon, báo cáo chi tiết hơn.

## Kiến trúc & đối tượng chính
- **Functions/Trigger**:
  - `recalc_sales_order_total` + `trg_order_lines_recalc`, `trg_sales_orders_recalc`: tính tổng đơn theo dòng, thuế, khuyến mãi.
  - `recalc_sales_order_payment` + triggers payments/refunds: cập nhật `paid_amount`, `payment_status`.
  - `fn_enforceIMEIAvailability`: chặn bán IMEI không ở trạng thái “On Shelf”.
  - `trg_shipments_inventory_update`, `trg_stock_transfers_apply`: đồng bộ tồn kho khi giao/nhận.
  - Loyalty: `apply_loyalty_payment`, `apply_loyalty_refund`, `ensure_loyalty_account`.
  - Audit: `fn_audit_products`, trigger staff audit.
- **RBAC/Auth**: roles, permission_scopes, role_permissions, user_accounts, user_sessions (có token_hash), refresh_tokens.
- **Report views**: `v_revenue_summary`, `v_inventory_by_warehouse`.

## Dữ liệu seed mặc định
- Lookup trạng thái đơn/kho/thanh toán, roles, staffs, customers, products mẫu, inventory IMEI, đơn bán + dòng, thanh toán, shipment, trả hàng + refund, promotions/tax_rates, warehouses, suppliers/purchase orders, loyalty transactions, service orders. Các script đều idempotent với `ON CONFLICT DO NOTHING`.
- Hash đăng nhập seed (demo): username `admin/sales/tech` với bcrypt mẫu (không dùng production).

## Việc có thể dọn/tuỳ chỉnh thêm
- Bảng không dùng: `mytable` (nếu không cần, drop).
- Hàm không dùng: nếu app không gọi `fn_calculatediscountvalue(numeric, integer)` có thể drop.
- `product_specifications` hiện rất nhiều dòng sample; có thể tinh gọn nếu chỉ cần ví dụ.
- Quyết định lưu/ẩn `session_token` thô; có thể giữ chỉ `token_hash`.
