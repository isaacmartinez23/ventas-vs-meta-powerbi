-- =============================================================================
-- 01_carga.sql · Carga de los 9 CSV de Olist y los 2 mapeos al esquema raw
-- Fuente: Brazilian E-Commerce Public Dataset by Olist (Kaggle, CC BY-NC-SA 4.0)
-- Los CSV deben estar en ./data (montado como /data en el contenedor).
-- Se cargan tal cual: sin filtros ni correcciones. La limpieza vive en 02.
-- =============================================================================

DROP SCHEMA IF EXISTS raw CASCADE;
CREATE SCHEMA raw;

-- ---------------------------------------------------------------- clientes
CREATE TABLE raw.customers (
    customer_id              text PRIMARY KEY,   -- uno por pedido
    customer_unique_id       text NOT NULL,      -- uno por persona
    customer_zip_code_prefix text,
    customer_city            text,
    customer_state           text
);

-- ------------------------------------------------------------ geolocalización
CREATE TABLE raw.geolocation (
    geolocation_zip_code_prefix text,
    geolocation_lat             numeric,
    geolocation_lng             numeric,
    geolocation_city            text,
    geolocation_state           text
);

-- ----------------------------------------------------------------- pedidos
CREATE TABLE raw.orders (
    order_id                      text PRIMARY KEY,
    customer_id                   text NOT NULL,
    order_status                  text,
    order_purchase_timestamp      timestamp,
    order_approved_at             timestamp,
    order_delivered_carrier_date  timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date timestamp
);

-- ---------------------------------------------------------------- partidas
CREATE TABLE raw.order_items (
    order_id            text,
    order_item_id       integer,
    product_id          text,
    seller_id           text,
    shipping_limit_date timestamp,
    price               numeric(12,2),
    freight_value       numeric(12,2),
    PRIMARY KEY (order_id, order_item_id)
);

-- ------------------------------------------------------------------- pagos
CREATE TABLE raw.order_payments (
    order_id             text,
    payment_sequential   integer,
    payment_type         text,
    payment_installments integer,
    payment_value        numeric(12,2),
    PRIMARY KEY (order_id, payment_sequential)
);

-- ----------------------------------------------------------------- reseñas
-- Sin llave primaria a propósito: review_id se repite entre pedidos y hay
-- pedidos con más de una reseña. Se resuelve en 03 con una función de ventana.
CREATE TABLE raw.order_reviews (
    review_id               text,
    order_id                text,
    review_score            integer,
    review_comment_title    text,
    review_comment_message  text,
    review_creation_date    timestamp,
    review_answer_timestamp timestamp
);

-- --------------------------------------------------------------- productos
-- El CSV trae "lenght" mal escrito en dos encabezados; aquí se corrige el nombre.
CREATE TABLE raw.products (
    product_id                 text PRIMARY KEY,
    product_category_name      text,
    product_name_length        numeric,
    product_description_length numeric,
    product_photos_qty         numeric,
    product_weight_g           numeric,
    product_length_cm          numeric,
    product_height_cm          numeric,
    product_width_cm           numeric
);

-- -------------------------------------------------------------- vendedores
CREATE TABLE raw.sellers (
    seller_id              text PRIMARY KEY,
    seller_zip_code_prefix text,
    seller_city            text,
    seller_state           text
);

-- ------------------------------------------------- traducción de categorías
CREATE TABLE raw.category_translation (
    product_category_name         text PRIMARY KEY,
    product_category_name_english text
);

-- ------------------------------------------------------- mapeos (propios)
-- Las mismas tablas se copian a Metas_2018.xlsx: una sola definición de
-- grupo y región para SQL, Excel y Power BI.
CREATE TABLE raw.mapeo_categorias (
    categoria text PRIMARY KEY,
    grupo     text NOT NULL
);

CREATE TABLE raw.mapeo_estados (
    estado        text PRIMARY KEY,
    nombre_estado text NOT NULL,
    region        text NOT NULL
);

-- =============================================================================
-- COPY
-- =============================================================================
COPY raw.customers            FROM '/data/olist_customers_dataset.csv'            WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.geolocation          FROM '/data/olist_geolocation_dataset.csv'          WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.orders               FROM '/data/olist_orders_dataset.csv'               WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.order_items          FROM '/data/olist_order_items_dataset.csv'          WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.order_payments       FROM '/data/olist_order_payments_dataset.csv'       WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.order_reviews        FROM '/data/olist_order_reviews_dataset.csv'        WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.products             FROM '/data/olist_products_dataset.csv'             WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.sellers              FROM '/data/olist_sellers_dataset.csv'              WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.mapeo_categorias     FROM '/data/mapeos/mapeo_categorias.csv'            WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
COPY raw.mapeo_estados        FROM '/data/mapeos/mapeo_estados.csv'               WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

-- La traducción de categorías es opcional (solo alimenta categoria_en):
-- si el archivo no está, se avisa y la carga continúa.
DO $$
BEGIN
    IF pg_stat_file('/data/product_category_name_translation.csv', true) IS NULL THEN
        RAISE WARNING 'Falta product_category_name_translation.csv: categoria_en usará el nombre en portugués';
    ELSE
        COPY raw.category_translation FROM '/data/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
    END IF;
END $$;

-- =============================================================================
-- Conteos por tabla
-- =============================================================================
SELECT 'customers' AS tabla, COUNT(*) AS filas FROM raw.customers
UNION ALL SELECT 'geolocation',          COUNT(*) FROM raw.geolocation
UNION ALL SELECT 'orders',               COUNT(*) FROM raw.orders
UNION ALL SELECT 'order_items',          COUNT(*) FROM raw.order_items
UNION ALL SELECT 'order_payments',       COUNT(*) FROM raw.order_payments
UNION ALL SELECT 'order_reviews',        COUNT(*) FROM raw.order_reviews
UNION ALL SELECT 'products',             COUNT(*) FROM raw.products
UNION ALL SELECT 'sellers',              COUNT(*) FROM raw.sellers
UNION ALL SELECT 'category_translation', COUNT(*) FROM raw.category_translation
UNION ALL SELECT 'mapeo_categorias',     COUNT(*) FROM raw.mapeo_categorias
UNION ALL SELECT 'mapeo_estados',        COUNT(*) FROM raw.mapeo_estados
ORDER BY 1;
