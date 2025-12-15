--
-- PostgreSQL database dump
--

\restrict f3XsaAYkfzU1rGZQ80j5g0jM2meD1oTqKRhM3I3fDEJRQZnCQnLabO6glIOE4hQ

-- Dumped from database version 16.11 (Ubuntu 16.11-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.11 (Ubuntu 16.11-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: fn_audit_products(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_audit_products() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO product_audit_logs (
      action, product_code, entity, details
    )
    VALUES (
      'INSERT',
      NEW.product_code,
      'PRODUCT',
      to_jsonb(NEW)
    );
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO product_audit_logs (
      action, product_code, entity, details
    )
    VALUES (
      'UPDATE',
      NEW.product_code,
      'PRODUCT',
      jsonb_build_object(
        'before', to_jsonb(OLD),
        'after',  to_jsonb(NEW)
      )
    );
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO product_audit_logs (
      action, product_code, entity, details
    )
    VALUES (
      'DELETE',
      OLD.product_code,
      'PRODUCT',
      to_jsonb(OLD)
    );
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;


--
-- Name: fn_auditproductchanges(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_auditproductchanges() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO product_audit_logs (
        action,
        product_code,
        details
    )
    VALUES (
        TG_OP,                          -- 'INSERT' | 'UPDATE' | 'DELETE'
        NEW.product_code,
        to_jsonb(NEW)
    );

    RETURN NEW;
END;
$$;


--
-- Name: fn_audituseraccess(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_audituseraccess() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.role_id IS DISTINCT FROM NEW.role_id THEN
            INSERT INTO staff_audit_logs(
                staff_id,
                action_type,
                old_role_id,
                new_role_id,
                changed_at,
                changed_by
            )
            VALUES (
                NEW.staff_id,
                'UPDATE',
                OLD.role_id,
                NEW.role_id,
                NOW(),
                current_user
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: fn_calculatediscountvalue(numeric, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_calculatediscountvalue(p_base_price numeric, p_promotion_id integer) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_discount_percentage NUMERIC;
BEGIN
    SELECT discount_percentage
    INTO v_discount_percentage
    FROM promotions
    WHERE id = p_promotion_id;

    v_discount_percentage := COALESCE(v_discount_percentage, 0);
    RETURN (p_base_price * v_discount_percentage / 100);
END;
$$;


--
-- Name: fn_enforceimeiavailability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_enforceimeiavailability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_available_status_id INT;
    v_current_status_id   INT;
BEGIN
    -- Lấy id cho trạng thái 'On Shelf' (cho phép bán)
    SELECT id INTO v_available_status_id
    FROM lookup_stock_statuses
    WHERE status_name = 'On Shelf';

    IF v_available_status_id IS NULL THEN
        RAISE EXCEPTION 'Chưa cấu hình status "On Shelf" trong lookup_stock_statuses';
    END IF;

    -- Lấy trạng thái hiện tại của IMEI trong inventory_items
    SELECT stock_status_id INTO v_current_status_id
    FROM inventory_items
    WHERE imei = NEW.imei;

    IF v_current_status_id IS NULL THEN
        RAISE EXCEPTION 'IMEI % không tồn tại trong inventory_items', NEW.imei;
    END IF;

    IF v_current_status_id <> v_available_status_id THEN
        RAISE EXCEPTION 'IMEI % hiện không ở trạng thái cho phép bán ("On Shelf")', NEW.imei;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: fn_getproductspec(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_getproductspec(p_product_code text, p_spec_name text) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_result TEXT;
BEGIN
    SELECT ps.spec_value
    INTO v_result
    FROM product_specifications ps
    WHERE ps.product_code = p_product_code
      AND ps.spec_name = UPPER(p_spec_name);

    RETURN COALESCE(v_result, 'NOT_FOUND');
END;
$$;


--
-- Name: recalc_sales_order_total(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalc_sales_order_total(p_order_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_subtotal numeric := 0;
  v_promo_pct numeric := 0;
  v_tax_rate numeric := 0;
  v_discount_amt numeric := 0;
  v_tax_amt numeric := 0;
  v_total numeric := 0;
BEGIN
  SELECT COALESCE(SUM(COALESCE(selling_price,0)),0)
    INTO v_subtotal
  FROM order_lines
  WHERE order_id = p_order_id;

  SELECT COALESCE((SELECT discount_percentage FROM promotions p JOIN sales_orders so ON so.promotion_id = p.id WHERE so.id = p_order_id),0)
    INTO v_promo_pct;

  SELECT COALESCE((SELECT rate FROM tax_rates t JOIN sales_orders so ON so.tax_rate_id = t.id WHERE so.id = p_order_id),0)
    INTO v_tax_rate;

  v_discount_amt := v_subtotal * v_promo_pct / 100;
  IF v_discount_amt < 0 THEN v_discount_amt := 0; END IF;

  v_tax_amt := (v_subtotal - v_discount_amt) * v_tax_rate / 100;
  IF v_tax_amt < 0 THEN v_tax_amt := 0; END IF;

  v_total := (v_subtotal - v_discount_amt) + v_tax_amt;
  IF v_total < 0 THEN v_total := 0; END IF;

  UPDATE sales_orders
    SET total_amount = v_total
  WHERE id = p_order_id;
END;
$$;


--
-- Name: sp_adjustinventory(integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_adjustinventory(p_inventory_item_id integer, p_new_stock_status_name text, p_note text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_new_status_id INT;
BEGIN
    -- Lấy status_id tương ứng
    SELECT status_id INTO v_new_status_id
    FROM lookup_stock_statuses
    WHERE status_name = p_new_stock_status_name;

    IF v_new_status_id IS NULL THEN
        RAISE EXCEPTION 'Status "%" không tồn tại trong lookup_stock_statuses', p_new_stock_status_name;
    END IF;

    -- Cập nhật trạng thái tồn kho
    UPDATE inventory_items
    SET stock_status_id = v_new_status_id
    WHERE inventory_item_id = p_inventory_item_id;

    -- Nếu bạn có bảng log riêng cho điều chỉnh tồn kho thì INSERT thêm ở đây.
END;
$$;


--
-- Name: sp_processreturn(integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_processreturn(p_order_line_id integer, p_return_reason text, p_return_type text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_inventory_item_id     INT;
    v_order_id              INT;
    v_returned_status_id    INT;
    v_available_status_id   INT;
    v_refunded_status_id    INT;
BEGIN
    -- Lấy thông tin từ OrderLines
    SELECT ol.inventory_item_id,
           ol.order_id
    INTO v_inventory_item_id, v_order_id
    FROM order_lines ol
    WHERE ol.order_line_id = p_order_line_id;

    IF v_inventory_item_id IS NULL THEN
        RAISE EXCEPTION 'order_line_id % không tồn tại', p_order_line_id;
    END IF;

    -- Lấy ID các trạng thái
    SELECT status_id INTO v_returned_status_id
    FROM lookup_stock_statuses
    WHERE status_name = 'Returned';

    SELECT status_id INTO v_available_status_id
    FROM lookup_stock_statuses
    WHERE status_name = 'Available';

    IF v_returned_status_id IS NULL OR v_available_status_id IS NULL THEN
        RAISE EXCEPTION 'Chưa cấu hình status "Returned" hoặc "Available" trong lookup_stock_statuses';
    END IF;

    SELECT order_status_id INTO v_refunded_status_id
    FROM lookup_order_statuses
    WHERE status_name = 'Refunded';

    IF v_refunded_status_id IS NULL THEN
        RAISE EXCEPTION 'Chưa cấu hình status "Refunded" trong lookup_order_statuses';
    END IF;

    -- Ghi nhận bản ghi hoàn trả
    INSERT INTO return_records(
        order_line_id,
        inventory_item_id,
        return_reason,
        return_type,
        created_at
    )
    VALUES (
        p_order_line_id,
        v_inventory_item_id,
        p_return_reason,
        p_return_type,
        NOW()
    );

    -- Cập nhật trạng thái IMEI tuỳ theo loại hoàn trả
    IF LOWER(p_return_type) = 'refund' THEN
        -- Hoàn tiền, đưa về trạng thái 'Returned'
        UPDATE inventory_items
        SET stock_status_id = v_returned_status_id
        WHERE inventory_item_id = v_inventory_item_id;
    ELSIF LOWER(p_return_type) = 'exchange' THEN
        -- Đổi sang máy khác, hàng cũ được đưa lại kho (Available)
        UPDATE inventory_items
        SET stock_status_id = v_available_status_id
        WHERE inventory_item_id = v_inventory_item_id;
    ELSE
        -- Mặc định vẫn cho là hàng trả -> Returned
        UPDATE inventory_items
        SET stock_status_id = v_returned_status_id
        WHERE inventory_item_id = v_inventory_item_id;
    END IF;

    -- Đơn giản: Đánh dấu đơn hàng là Refunded
    UPDATE orders
    SET order_status_id = v_refunded_status_id
    WHERE order_id = v_order_id;
END;
$$;


--
-- Name: sp_processsale(integer, text, text, integer, integer, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_processsale(p_staff_id integer, p_customer_name text, p_customer_phone text, p_payment_method_id integer, p_tax_rate_id integer, p_imei_list text[]) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_order_id              INT;
    v_inventory_item_id     INT;
    v_product_id            INT;
    v_unit_price            NUMERIC(12,2);
    v_subtotal              NUMERIC(12,2) := 0;
    v_tax_rate              NUMERIC(5,2);
    v_tax_amount            NUMERIC(12,2);
    v_total                 NUMERIC(12,2);
    v_available_status_id   INT;
    v_sold_status_id        INT;
    v_status_id             INT;
    v_ref_completed_id      INT;
    v_imei                  TEXT;
BEGIN
    -- Lấy ID trạng thái tồn kho
    SELECT status_id INTO v_available_status_id
    FROM lookup_stock_statuses
    WHERE status_name = 'Available';

    SELECT status_id INTO v_sold_status_id
    FROM lookup_stock_statuses
    WHERE status_name = 'Sold';

    IF v_available_status_id IS NULL OR v_sold_status_id IS NULL THEN
        RAISE EXCEPTION 'Chưa cấu hình status "Available" hoặc "Sold" trong lookup_stock_statuses';
    END IF;

    -- Lấy tax rate
    SELECT rate INTO v_tax_rate
    FROM tax_rates
    WHERE tax_rate_id = p_tax_rate_id;

    IF v_tax_rate IS NULL THEN
        RAISE EXCEPTION 'tax_rate_id % không hợp lệ', p_tax_rate_id;
    END IF;

    -- Lấy order_status_id cho trạng thái Completed
    SELECT order_status_id INTO v_ref_completed_id
    FROM lookup_order_statuses
    WHERE status_name = 'Completed';

    IF v_ref_completed_id IS NULL THEN
        RAISE EXCEPTION 'Chưa cấu hình status "Completed" trong lookup_order_statuses';
    END IF;

    -- Tạo đơn hàng rỗng trước, subtotal/tax/total sẽ cập nhật lại sau
    INSERT INTO orders(
        customer_name,
        customer_phone,
        staff_id,
        payment_method_id,
        order_status_id,
        tax_rate_id,
        subtotal,
        tax_amount,
        total_amount,
        created_at
    )
    VALUES (
        p_customer_name,
        p_customer_phone,
        p_staff_id,
        p_payment_method_id,
        v_ref_completed_id,
        p_tax_rate_id,
        0,
        0,
        0,
        NOW()
    )
    RETURNING order_id INTO v_order_id;

    -- Duyệt từng IMEI trong mảng
    FOREACH v_imei IN ARRAY p_imei_list
    LOOP
        SELECT ii.inventory_item_id,
               ii.stock_status_id,
               p.product_id,
               p.selling_price
        INTO v_inventory_item_id, v_status_id, v_product_id, v_unit_price
        FROM inventory_items ii
        JOIN products p ON p.product_id = ii.product_id
        WHERE ii.imei = v_imei;

        IF v_inventory_item_id IS NULL THEN
            RAISE EXCEPTION 'IMEI % không tồn tại trong inventory_items', v_imei;
        END IF;

        IF v_status_id <> v_available_status_id THEN
            RAISE EXCEPTION 'IMEI % hiện không ở trạng thái "Available"', v_imei;
        END IF;

        -- Chèn dòng chi tiết đơn hàng
        INSERT INTO order_lines(
            order_id,
            inventory_item_id,
            quantity,
            unit_price,
            line_total
        )
        VALUES (
            v_order_id,
            v_inventory_item_id,
            1,
            v_unit_price,
            v_unit_price
        );

        v_subtotal := v_subtotal + v_unit_price;

        -- Cập nhật trạng thái IMEI sang 'Sold'
        UPDATE inventory_items
        SET stock_status_id = v_sold_status_id
        WHERE inventory_item_id = v_inventory_item_id;
    END LOOP;

    -- Tính thuế và tổng tiền
    v_tax_amount := ROUND(v_subtotal * v_tax_rate / 100.0, 2);
    v_total      := v_subtotal + v_tax_amount;

    UPDATE orders
    SET subtotal    = v_subtotal,
        tax_amount  = v_tax_amount,
        total_amount= v_total
    WHERE order_id = v_order_id;

    RETURN v_order_id;
END;
$$;


--
-- Name: trg_order_lines_recalc(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_order_lines_recalc() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM recalc_sales_order_total(CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END);
  RETURN NULL;
END;
$$;


--
-- Name: trg_sales_orders_recalc(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_sales_orders_recalc() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM recalc_sales_order_total(NEW.id);
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id integer NOT NULL,
    staff_id integer NOT NULL,
    operation_time timestamp without time zone,
    table_name character varying(100),
    record_id character varying(100),
    operation_type character varying(50),
    details text
);


--
-- Name: audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_logs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.audit_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id integer NOT NULL,
    name character varying(100),
    phone character varying(30),
    email character varying(255),
    created_at timestamp without time zone
);


--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.customers ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: inventory_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_items (
    imei character varying(50) NOT NULL,
    product_code character varying(50) NOT NULL,
    stock_status_id integer NOT NULL,
    receipt_date date
);


--
-- Name: lookup_order_statuses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lookup_order_statuses (
    id integer NOT NULL,
    status_name character varying(100) NOT NULL
);


--
-- Name: lookup_order_statuses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lookup_order_statuses ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lookup_order_statuses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lookup_payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lookup_payment_methods (
    id integer NOT NULL,
    method_name character varying(100) NOT NULL
);


--
-- Name: lookup_payment_methods_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lookup_payment_methods ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lookup_payment_methods_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lookup_stock_statuses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lookup_stock_statuses (
    id integer NOT NULL,
    status_name character varying(100) NOT NULL
);


--
-- Name: lookup_stock_statuses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lookup_stock_statuses ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lookup_stock_statuses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: mytable; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mytable (
    brand character varying(50) NOT NULL,
    model character varying(100) NOT NULL,
    color character varying(30),
    memory character varying(6),
    storage character varying(21),
    camera character varying(6),
    rating character varying(6),
    selling_price character varying(13),
    original_price character varying(14),
    mobile character varying(48),
    discount character varying(8),
    discount_percentage character varying(20)
);


--
-- Name: order_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_lines (
    order_id integer NOT NULL,
    imei character varying(50) NOT NULL,
    selling_price numeric(12,2),
    CONSTRAINT order_lines_price_nonneg CHECK (((selling_price IS NULL) OR (selling_price >= (0)::numeric)))
);


--
-- Name: product_audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_audit_logs (
    id bigint NOT NULL,
    action text NOT NULL,
    product_code character varying(50) NOT NULL,
    entity text DEFAULT 'PRODUCT'::text NOT NULL,
    details jsonb NOT NULL,
    changed_at timestamp without time zone DEFAULT now() NOT NULL,
    changed_by text DEFAULT CURRENT_USER NOT NULL
);


--
-- Name: product_audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_audit_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_audit_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_audit_logs_id_seq OWNED BY public.product_audit_logs.id;


--
-- Name: product_specifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_specifications (
    product_code character varying(50) NOT NULL,
    spec_name character varying(100) NOT NULL,
    spec_value character varying(255)
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    product_code character varying(50) NOT NULL,
    brand character varying(100),
    model_name character varying(200),
    base_price numeric(10,2),
    warranty_period integer,
    CONSTRAINT products_base_price_nonneg CHECK (((base_price IS NULL) OR (base_price >= (0)::numeric))),
    CONSTRAINT products_warranty_nonneg CHECK (((warranty_period IS NULL) OR (warranty_period >= 0)))
);


--
-- Name: promotions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.promotions (
    id integer NOT NULL,
    promo_name character varying(100),
    discount_percentage numeric(5,2),
    start_date timestamp without time zone,
    end_date timestamp without time zone,
    CONSTRAINT promotions_dates CHECK (((start_date IS NULL) OR (end_date IS NULL) OR (start_date <= end_date))),
    CONSTRAINT promotions_discount_range CHECK (((discount_percentage IS NULL) OR ((discount_percentage >= (0)::numeric) AND (discount_percentage <= (100)::numeric))))
);


--
-- Name: promotions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.promotions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.promotions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: return_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.return_records (
    id integer NOT NULL,
    order_id integer NOT NULL,
    imei character varying(50) NOT NULL,
    return_date date,
    reason text,
    refund_amount numeric(12,2),
    CONSTRAINT return_records_refund_nonneg CHECK (((refund_amount IS NULL) OR (refund_amount >= (0)::numeric)))
);


--
-- Name: return_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.return_records ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.return_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id integer NOT NULL,
    role_name character varying(100) NOT NULL
);


--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.roles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sales_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_orders (
    id integer NOT NULL,
    customer_id integer NOT NULL,
    staff_id integer NOT NULL,
    order_date timestamp without time zone,
    total_amount numeric(12,2),
    payment_method_id integer,
    order_status_id integer,
    tax_rate_id integer,
    promotion_id integer,
    CONSTRAINT sales_orders_total_nonneg CHECK (((total_amount IS NULL) OR (total_amount >= (0)::numeric)))
);


--
-- Name: sales_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sales_orders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sales_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: staff_audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_audit_logs (
    id bigint NOT NULL,
    action text NOT NULL,
    staff_id integer NOT NULL,
    details jsonb NOT NULL,
    changed_at timestamp without time zone DEFAULT now() NOT NULL,
    changed_by text DEFAULT CURRENT_USER NOT NULL
);


--
-- Name: staff_audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.staff_audit_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: staff_audit_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.staff_audit_logs_id_seq OWNED BY public.staff_audit_logs.id;


--
-- Name: staffs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staffs (
    id integer NOT NULL,
    role_id integer NOT NULL,
    name character varying(100),
    phone character varying(30),
    email character varying(255),
    created_at timestamp without time zone
);


--
-- Name: staffs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.staffs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.staffs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tax_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tax_rates (
    id integer NOT NULL,
    tax_name character varying(100),
    rate numeric(10,2),
    start_date date,
    end_date date,
    CONSTRAINT tax_rates_range CHECK (((rate IS NULL) OR (rate >= (0)::numeric)))
);


--
-- Name: tax_rates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tax_rates ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.tax_rates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: product_audit_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_audit_logs ALTER COLUMN id SET DEFAULT nextval('public.product_audit_logs_id_seq'::regclass);


--
-- Name: staff_audit_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_audit_logs ALTER COLUMN id SET DEFAULT nextval('public.staff_audit_logs_id_seq'::regclass);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: customers customers_email_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_email_unique UNIQUE (email);


--
-- Name: customers customers_phone_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_phone_unique UNIQUE (phone);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: inventory_items inventory_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT inventory_items_pkey PRIMARY KEY (imei);


--
-- Name: lookup_order_statuses lookup_order_statuses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lookup_order_statuses
    ADD CONSTRAINT lookup_order_statuses_pkey PRIMARY KEY (id);


--
-- Name: lookup_payment_methods lookup_payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lookup_payment_methods
    ADD CONSTRAINT lookup_payment_methods_pkey PRIMARY KEY (id);


--
-- Name: lookup_stock_statuses lookup_stock_statuses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lookup_stock_statuses
    ADD CONSTRAINT lookup_stock_statuses_pkey PRIMARY KEY (id);


--
-- Name: order_lines pk_order_lines; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_lines
    ADD CONSTRAINT pk_order_lines PRIMARY KEY (order_id, imei);


--
-- Name: product_specifications pk_product_specifications; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_specifications
    ADD CONSTRAINT pk_product_specifications PRIMARY KEY (product_code, spec_name);


--
-- Name: product_audit_logs product_audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_audit_logs
    ADD CONSTRAINT product_audit_logs_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_code);


--
-- Name: promotions promotions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.promotions
    ADD CONSTRAINT promotions_pkey PRIMARY KEY (id);


--
-- Name: return_records return_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_records
    ADD CONSTRAINT return_records_pkey PRIMARY KEY (id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: sales_orders sales_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_pkey PRIMARY KEY (id);


--
-- Name: staff_audit_logs staff_audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_audit_logs
    ADD CONSTRAINT staff_audit_logs_pkey PRIMARY KEY (id);


--
-- Name: staffs staffs_email_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staffs
    ADD CONSTRAINT staffs_email_unique UNIQUE (email);


--
-- Name: staffs staffs_phone_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staffs
    ADD CONSTRAINT staffs_phone_unique UNIQUE (phone);


--
-- Name: staffs staffs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staffs
    ADD CONSTRAINT staffs_pkey PRIMARY KEY (id);


--
-- Name: tax_rates tax_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_rates
    ADD CONSTRAINT tax_rates_pkey PRIMARY KEY (id);


--
-- Name: lookup_order_statuses uq_lookup_order_statuses_status_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lookup_order_statuses
    ADD CONSTRAINT uq_lookup_order_statuses_status_name UNIQUE (status_name);


--
-- Name: lookup_stock_statuses uq_lookup_stock_statuses_status_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lookup_stock_statuses
    ADD CONSTRAINT uq_lookup_stock_statuses_status_name UNIQUE (status_name);


--
-- Name: order_lines order_lines_recalc_total; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER order_lines_recalc_total AFTER INSERT OR DELETE OR UPDATE ON public.order_lines FOR EACH ROW EXECUTE FUNCTION public.trg_order_lines_recalc();


--
-- Name: sales_orders sales_orders_recalc_total; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sales_orders_recalc_total AFTER INSERT OR UPDATE OF promotion_id, tax_rate_id ON public.sales_orders FOR EACH ROW EXECUTE FUNCTION public.trg_sales_orders_recalc();


--
-- Name: staffs tr_audituseraccess; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_audituseraccess AFTER UPDATE ON public.staffs FOR EACH ROW EXECUTE FUNCTION public.fn_audituseraccess();


--
-- Name: order_lines tr_enforceimeiavailability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_enforceimeiavailability BEFORE INSERT ON public.order_lines FOR EACH ROW EXECUTE FUNCTION public.fn_enforceimeiavailability();


--
-- Name: products trg_audit_products; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_products AFTER INSERT OR DELETE OR UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.fn_audit_products();


--
-- Name: audit_logs fk_audit_staff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT fk_audit_staff FOREIGN KEY (staff_id) REFERENCES public.staffs(id);


--
-- Name: inventory_items fk_inventory_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT fk_inventory_product FOREIGN KEY (product_code) REFERENCES public.products(product_code);


--
-- Name: inventory_items fk_inventory_stock_status; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT fk_inventory_stock_status FOREIGN KEY (stock_status_id) REFERENCES public.lookup_stock_statuses(id);


--
-- Name: order_lines fk_order_lines_imei; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_lines
    ADD CONSTRAINT fk_order_lines_imei FOREIGN KEY (imei) REFERENCES public.inventory_items(imei);


--
-- Name: order_lines fk_order_lines_order; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_lines
    ADD CONSTRAINT fk_order_lines_order FOREIGN KEY (order_id) REFERENCES public.sales_orders(id);


--
-- Name: product_specifications fk_product_spec_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_specifications
    ADD CONSTRAINT fk_product_spec_product FOREIGN KEY (product_code) REFERENCES public.products(product_code);


--
-- Name: return_records fk_return_imei; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_records
    ADD CONSTRAINT fk_return_imei FOREIGN KEY (imei) REFERENCES public.inventory_items(imei);


--
-- Name: return_records fk_return_order; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_records
    ADD CONSTRAINT fk_return_order FOREIGN KEY (order_id) REFERENCES public.sales_orders(id);


--
-- Name: sales_orders fk_sales_customer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT fk_sales_customer FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: sales_orders fk_sales_order_status; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT fk_sales_order_status FOREIGN KEY (order_status_id) REFERENCES public.lookup_order_statuses(id);


--
-- Name: sales_orders fk_sales_payment_method; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT fk_sales_payment_method FOREIGN KEY (payment_method_id) REFERENCES public.lookup_payment_methods(id);


--
-- Name: sales_orders fk_sales_promotion; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT fk_sales_promotion FOREIGN KEY (promotion_id) REFERENCES public.promotions(id);


--
-- Name: sales_orders fk_sales_staff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT fk_sales_staff FOREIGN KEY (staff_id) REFERENCES public.staffs(id);


--
-- Name: sales_orders fk_sales_tax_rate; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT fk_sales_tax_rate FOREIGN KEY (tax_rate_id) REFERENCES public.tax_rates(id);


--
-- Name: staffs fk_staffs_role; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staffs
    ADD CONSTRAINT fk_staffs_role FOREIGN KEY (role_id) REFERENCES public.roles(id);


--
-- PostgreSQL database dump complete
--

\unrestrict f3XsaAYkfzU1rGZQ80j5g0jM2meD1oTqKRhM3I3fDEJRQZnCQnLabO6glIOE4hQ

