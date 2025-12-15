--Insert 
INSERT INTO products (
  product_code, brand, model_name, base_price, warranty_period
)
SELECT DISTINCT
  'P-' || substr(md5(
      coalesce(brand,'') || '|' ||
      coalesce(model,'') || '|' ||
      coalesce(memory,'NA') || '|' ||
      coalesce(storage,'NA') || '|' ||
      coalesce(color,'NA')
  ), 1, 32) AS product_code,          -- luôn <= 34 ký tự (P- + 32)
  brand,
  model AS model_name,
  selling_price::numeric AS base_price,
  12 AS warranty_period
FROM mytable
WHERE brand IS NOT NULL
  AND model IS NOT NULL
  AND selling_price IS NOT NULL
ON CONFLICT (product_code) DO NOTHING;



-- RAM
INSERT INTO product_specifications (product_code, spec_name, spec_value)
SELECT DISTINCT
  'P-' || substr(md5(
      coalesce(brand,'') || '|' ||
      coalesce(model,'') || '|' ||
      coalesce(memory,'NA') || '|' ||
      coalesce(storage,'NA') || '|' ||
      coalesce(color,'NA')
  ), 1, 32) AS product_code,
  'RAM' AS spec_name,
  memory AS spec_value
FROM mytable
WHERE memory IS NOT NULL AND trim(memory) <> ''
ON CONFLICT (product_code, spec_name) DO UPDATE
SET spec_value = EXCLUDED.spec_value;

-- STORAGE
INSERT INTO product_specifications (product_code, spec_name, spec_value)
SELECT DISTINCT
  'P-' || substr(md5(
      coalesce(brand,'') || '|' ||
      coalesce(model,'') || '|' ||
      coalesce(memory,'NA') || '|' ||
      coalesce(storage,'NA') || '|' ||
      coalesce(color,'NA')
  ), 1, 32),
  'STORAGE',
  storage
FROM mytable
WHERE storage IS NOT NULL AND trim(storage) <> ''
ON CONFLICT (product_code, spec_name) DO UPDATE
SET spec_value = EXCLUDED.spec_value;

-- COLOR
INSERT INTO product_specifications (product_code, spec_name, spec_value)
SELECT DISTINCT
  'P-' || substr(md5(
      coalesce(brand,'') || '|' ||
      coalesce(model,'') || '|' ||
      coalesce(memory,'NA') || '|' ||
      coalesce(storage,'NA') || '|' ||
      coalesce(color,'NA')
  ), 1, 32),
  'COLOR',
  color
FROM mytable
WHERE color IS NOT NULL AND trim(color) <> ''
ON CONFLICT (product_code, spec_name) DO UPDATE
SET spec_value = EXCLUDED.spec_value;

-- CAMERA
INSERT INTO product_specifications (product_code, spec_name, spec_value)
SELECT DISTINCT
  'P-' || substr(md5(
      coalesce(brand,'') || '|' ||
      coalesce(model,'') || '|' ||
      coalesce(memory,'NA') || '|' ||
      coalesce(storage,'NA') || '|' ||
      coalesce(color,'NA')
  ), 1, 32),
  'CAMERA',
  camera
FROM mytable
WHERE camera IS NOT NULL AND trim(camera) <> ''
ON CONFLICT (product_code, spec_name) DO UPDATE
SET spec_value = EXCLUDED.spec_value;

-- RATING (fix: group về 1 row / product_code trước khi upsert)
INSERT INTO product_specifications (product_code, spec_name, spec_value)
SELECT
  pc.product_code,
  'RATING' AS spec_name,
  pc.rating_value::text AS spec_value
FROM (
  SELECT
    'P-' || substr(md5(
        coalesce(brand,'') || '|' ||
        coalesce(model,'') || '|' ||
        coalesce(memory,'NA') || '|' ||
        coalesce(storage,'NA') || '|' ||
        coalesce(color,'NA')
    ), 1, 32) AS product_code,
    MAX(NULLIF(trim(rating), '')::numeric) AS rating_value
  FROM mytable
  WHERE rating IS NOT NULL AND trim(rating) <> ''
  GROUP BY 1
) pc
WHERE pc.rating_value IS NOT NULL
ON CONFLICT (product_code, spec_name) DO UPDATE
SET spec_value = EXCLUDED.spec_value;

-- ORIGINAL_PRICE
INSERT INTO product_specifications (product_code, spec_name, spec_value)
SELECT
  product_code,
  'ORIGINAL_PRICE',
  original_price_value::text
FROM (
  SELECT
    'P-' || substr(md5(
        coalesce(brand,'') || '|' ||
        coalesce(model,'') || '|' ||
        coalesce(memory,'NA') || '|' ||
        coalesce(storage,'NA') || '|' ||
        coalesce(color,'NA')
    ), 1, 32) AS product_code,
    MAX(NULLIF(trim(original_price), '')::numeric) AS original_price_value
  FROM mytable
  WHERE original_price IS NOT NULL AND trim(original_price) <> ''
  GROUP BY 1
) s
WHERE s.original_price_value IS NOT NULL
ON CONFLICT (product_code, spec_name) DO UPDATE
SET spec_value = EXCLUDED.spec_value;

-- DISCOUNT
INSERT INTO product_specifications (product_code, spec_name, spec_value)
SELECT
  product_code,
  'DISCOUNT',
  discount_value::text
FROM (
  SELECT
    'P-' || substr(md5(
        coalesce(brand,'') || '|' ||
        coalesce(model,'') || '|' ||
        coalesce(memory,'NA') || '|' ||
        coalesce(storage,'NA') || '|' ||
        coalesce(color,'NA')
    ), 1, 32) AS product_code,
    MAX(NULLIF(trim(discount), '')::numeric) AS discount_value
  FROM mytable
  WHERE discount IS NOT NULL AND trim(discount) <> ''
  GROUP BY 1
) s
WHERE s.discount_value IS NOT NULL
ON CONFLICT (product_code, spec_name) DO UPDATE
SET spec_value = EXCLUDED.spec_value;

-- DISCOUNT_PERCENTAGE
INSERT INTO product_specifications (product_code, spec_name, spec_value)
SELECT
  product_code,
  'DISCOUNT_PERCENTAGE',
  discount_pct_value::text
FROM (
  SELECT
    'P-' || substr(md5(
        coalesce(brand,'') || '|' ||
        coalesce(model,'') || '|' ||
        coalesce(memory,'NA') || '|' ||
        coalesce(storage,'NA') || '|' ||
        coalesce(color,'NA')
    ), 1, 32) AS product_code,
    MAX(
      NULLIF(
        trim(replace(discount_percentage, '%', '')),
        ''
      )::numeric
    ) AS discount_pct_value
  FROM mytable
  WHERE discount_percentage IS NOT NULL AND trim(discount_percentage) <> ''
  GROUP BY 1
) s
WHERE s.discount_pct_value IS NOT NULL
ON CONFLICT (product_code, spec_name) DO UPDATE
SET spec_value = EXCLUDED.spec_value;









