-- =============================================================================
-- 02_limpieza.sql · De raw a stg: tipos, nulos, duplicados y recorte del periodo
--
-- Decisiones (documentarlas en el caso):
--   1. Recorte: pedidos comprados de 2017-01-01 a 2018-08-31. 2016 y sep-oct 2018
--      tienen muy pocos pedidos y distorsionan cualquier comparación mensual.
--   2. Se excluyen pedidos sin partidas: no tienen precio ni producto.
--   3. Productos sin categoría -> 'sin_categoria' (grupo "Otros").
--   4. Las fechas de entrega nulas se conservan como NULL (no se imputan);
--      se marcan con una bandera para poder contarlas.
--   5. Las reseñas duplicadas NO se eliminan aquí: se elige la última por pedido
--      en 03_vistas.sql con ROW_NUMBER().
-- =============================================================================

DROP SCHEMA IF EXISTS stg CASCADE;
CREATE SCHEMA stg;

-- ----------------------------------------------------------------- pedidos
CREATE TABLE stg.pedidos AS
SELECT
    o.order_id,
    o.customer_id,
    LOWER(TRIM(o.order_status))               AS estatus,
    o.order_purchase_timestamp                AS ts_compra,
    o.order_purchase_timestamp::date          AS fecha_compra,
    o.order_approved_at                       AS ts_aprobado,
    o.order_delivered_carrier_date            AS ts_enviado,
    o.order_delivered_customer_date           AS ts_entregado,
    o.order_delivered_customer_date::date     AS fecha_entregado,
    o.order_estimated_delivery_date::date     AS fecha_estimada,
    -- Entregado según el estatus pero sin fecha de entrega registrada
    (LOWER(TRIM(o.order_status)) = 'delivered'
        AND o.order_delivered_customer_date IS NULL) AS entregado_sin_fecha
FROM raw.orders o
WHERE o.order_purchase_timestamp >= DATE '2017-01-01'
  AND o.order_purchase_timestamp <  DATE '2018-09-01'
  AND EXISTS (SELECT 1 FROM raw.order_items i WHERE i.order_id = o.order_id);

ALTER TABLE stg.pedidos ADD PRIMARY KEY (order_id);
CREATE INDEX ON stg.pedidos (customer_id);
CREATE INDEX ON stg.pedidos (fecha_compra);

-- ---------------------------------------------------------------- partidas
CREATE TABLE stg.partidas AS
SELECT
    i.order_id,
    i.order_item_id,
    i.product_id,
    i.seller_id,
    i.price         AS precio,
    i.freight_value AS flete
FROM raw.order_items i
JOIN stg.pedidos p USING (order_id);

ALTER TABLE stg.partidas ADD PRIMARY KEY (order_id, order_item_id);

-- ----------------------------------------------------------------- reseñas
CREATE TABLE stg.resenas AS
SELECT
    r.review_id,
    r.order_id,
    r.review_score            AS calificacion,
    r.review_creation_date    AS ts_creacion,
    r.review_answer_timestamp AS ts_respuesta
FROM raw.order_reviews r
JOIN stg.pedidos p USING (order_id)
WHERE r.review_score BETWEEN 1 AND 5;

CREATE INDEX ON stg.resenas (order_id);

-- --------------------------------------------------------------- productos
CREATE TABLE stg.productos AS
SELECT
    p.product_id,
    COALESCE(NULLIF(TRIM(p.product_category_name), ''), 'sin_categoria') AS categoria,
    p.product_weight_g AS peso_g
FROM raw.products p;

ALTER TABLE stg.productos ADD PRIMARY KEY (product_id);

-- ---------------------------------------------------------------- clientes
-- Solo los clientes con pedidos dentro del recorte.
CREATE TABLE stg.clientes AS
SELECT
    c.customer_id,
    c.customer_unique_id,
    INITCAP(TRIM(c.customer_city))  AS ciudad,
    UPPER(TRIM(c.customer_state))   AS estado
FROM raw.customers c
WHERE EXISTS (SELECT 1 FROM stg.pedidos p WHERE p.customer_id = c.customer_id);

ALTER TABLE stg.clientes ADD PRIMARY KEY (customer_id);

-- -------------------------------------------------------------- vendedores
CREATE TABLE stg.vendedores AS
SELECT
    s.seller_id,
    INITCAP(TRIM(s.seller_city)) AS ciudad,
    UPPER(TRIM(s.seller_state))  AS estado
FROM raw.sellers s;

ALTER TABLE stg.vendedores ADD PRIMARY KEY (seller_id);

-- Estadísticas para el planificador: sin esto, las vistas de 03 hacen joins
-- con planes malos sobre tablas recién creadas (minutos en vez de segundos).
ANALYZE;

-- =============================================================================
-- Bitácora de limpieza: cuánto se quitó y por qué (cifras para el caso)
-- =============================================================================
SELECT 'pedidos en raw'                              AS concepto, COUNT(*) AS n FROM raw.orders
UNION ALL
SELECT 'fuera del recorte ene 2017 - ago 2018',      COUNT(*) FROM raw.orders
 WHERE order_purchase_timestamp <  DATE '2017-01-01'
    OR order_purchase_timestamp >= DATE '2018-09-01'
UNION ALL
SELECT 'dentro del recorte pero sin partidas',       COUNT(*) FROM raw.orders o
 WHERE o.order_purchase_timestamp >= DATE '2017-01-01'
   AND o.order_purchase_timestamp <  DATE '2018-09-01'
   AND NOT EXISTS (SELECT 1 FROM raw.order_items i WHERE i.order_id = o.order_id)
UNION ALL
SELECT 'pedidos en stg',                             COUNT(*) FROM stg.pedidos
UNION ALL
SELECT 'entregados sin fecha de entrega',            COUNT(*) FROM stg.pedidos WHERE entregado_sin_fecha
UNION ALL
SELECT 'pedidos con más de una reseña',              COUNT(*) FROM (
        SELECT order_id FROM stg.resenas GROUP BY order_id HAVING COUNT(*) > 1) d
UNION ALL
SELECT 'pedidos sin reseña',                         COUNT(*) FROM stg.pedidos p
 WHERE NOT EXISTS (SELECT 1 FROM stg.resenas r WHERE r.order_id = p.order_id)
UNION ALL
SELECT 'productos sin categoría',                    COUNT(*) FROM stg.productos WHERE categoria = 'sin_categoria'
UNION ALL
SELECT 'categorías sin grupo en el mapeo',           COUNT(*) FROM (
        SELECT DISTINCT categoria FROM stg.productos
        EXCEPT SELECT categoria FROM raw.mapeo_categorias) d
UNION ALL
SELECT 'estados de cliente sin región en el mapeo',  COUNT(*) FROM (
        SELECT DISTINCT estado FROM stg.clientes
        EXCEPT SELECT estado FROM raw.mapeo_estados) d;
