-- =============================================================================
-- 03_vistas.sql · Las 7 vistas del esquema bi que consume Power BI
--
--   vw_dim_producto     una fila por producto, con categoría y grupo
--   vw_dim_cliente      una fila por customer_id, con estado y región
--   vw_dim_vendedor     una fila por vendedor, con estado y región
--   vw_fact_ventas      una fila por partida (precio y flete)
--   vw_fact_pedidos     una fila por pedido (entrega, retraso, calificación)
--   vw_base_2017        ventas 2017 por mes x grupo x región -> Metas_2018.xlsx
--   vw_resumen_mensual  totales por mes para cuadrar contra DAX
--
-- Decisiones:
--   * "Venta" = partida de un pedido que no está cancelado ni 'unavailable'.
--     fact_pedidos sí conserva todos los estatus (lo necesita Cancelación %).
--   * La fecha de la venta es la fecha de compra, no la de entrega.
--   * dias_retraso = fecha de entrega - fecha estimada. Positivo = llegó tarde.
-- =============================================================================

DROP SCHEMA IF EXISTS bi CASCADE;
CREATE SCHEMA bi;

-- ------------------------------------------------------------ dim producto
CREATE VIEW bi.vw_dim_producto AS
SELECT
    p.product_id,
    p.categoria,
    COALESCE(REPLACE(t.product_category_name_english, '_', ' '), p.categoria) AS categoria_en,
    COALESCE(m.grupo, 'Otros') AS grupo
FROM stg.productos p
LEFT JOIN raw.category_translation t ON t.product_category_name = p.categoria
LEFT JOIN raw.mapeo_categorias     m ON m.categoria = p.categoria;

-- ------------------------------------------------------------- dim cliente
-- customer_id relaciona con los hechos; customer_unique_id cuenta personas.
CREATE VIEW bi.vw_dim_cliente AS
SELECT
    c.customer_id,
    c.customer_unique_id,
    c.ciudad,
    c.estado,
    e.nombre_estado,
    e.region
FROM stg.clientes c
LEFT JOIN raw.mapeo_estados e ON e.estado = c.estado;

-- ------------------------------------------------------------ dim vendedor
CREATE VIEW bi.vw_dim_vendedor AS
SELECT
    s.seller_id,
    s.ciudad,
    s.estado,
    e.nombre_estado,
    e.region
FROM stg.vendedores s
LEFT JOIN raw.mapeo_estados e ON e.estado = s.estado;

-- ------------------------------------------------------------- fact ventas
-- Granularidad: partida. El precio y el flete viven aquí.
CREATE VIEW bi.vw_fact_ventas AS
SELECT
    i.order_id,
    i.order_item_id,
    p.fecha_compra AS fecha,
    p.customer_id,
    c.customer_unique_id,
    i.product_id,
    i.seller_id,
    i.precio,
    i.flete
FROM stg.partidas i
JOIN stg.pedidos  p USING (order_id)
JOIN stg.clientes c USING (customer_id)
WHERE p.estatus NOT IN ('canceled', 'unavailable');

-- ------------------------------------------------------------ fact pedidos
-- Granularidad: pedido. La entrega y la reseña viven aquí.
CREATE VIEW bi.vw_fact_pedidos AS
WITH ultima_resena AS (
    -- Un pedido puede tener varias reseñas: nos quedamos con la más reciente.
    SELECT order_id, calificacion
    FROM (
        SELECT
            r.order_id,
            r.calificacion,
            ROW_NUMBER() OVER (
                PARTITION BY r.order_id
                ORDER BY r.ts_respuesta DESC NULLS LAST,
                         r.ts_creacion  DESC NULLS LAST,
                         r.review_id
            ) AS rn
        FROM stg.resenas r
    ) x
    WHERE rn = 1
),
totales AS (
    SELECT
        order_id,
        COUNT(*)                  AS num_partidas,
        COUNT(DISTINCT seller_id) AS num_vendedores,
        SUM(precio)               AS valor_pedido,
        SUM(flete)                AS flete_pedido
    FROM stg.partidas
    GROUP BY order_id
)
SELECT
    p.order_id,
    p.fecha_compra AS fecha,
    p.customer_id,
    p.estatus,
    p.fecha_entregado,
    p.fecha_estimada,
    (p.fecha_entregado - p.fecha_compra)   AS dias_entrega,
    (p.fecha_entregado - p.fecha_estimada) AS dias_retraso,
    CASE
        WHEN p.fecha_entregado IS NULL            THEN NULL
        WHEN p.fecha_entregado > p.fecha_estimada THEN 'Tarde'
        ELSE 'A tiempo'
    END AS entrega,
    u.calificacion,
    t.num_partidas,
    t.num_vendedores,
    t.valor_pedido,
    t.flete_pedido
FROM stg.pedidos p
JOIN totales t            USING (order_id)
LEFT JOIN ultima_resena u USING (order_id);

-- --------------------------------------------------------------- base 2017
-- Lo que se exporta a la hoja base_2017 de Metas_2018.xlsx.
-- Rejilla completa mes x grupo x región (con ceros) para que el XLOOKUP de
-- Excel nunca devuelva #N/A.
CREATE VIEW bi.vw_base_2017 AS
WITH meses AS (
    SELECT generate_series(DATE '2017-01-01', DATE '2017-12-01', INTERVAL '1 month')::date AS mes
),
grupos   AS (SELECT DISTINCT grupo  FROM raw.mapeo_categorias),
regiones AS (SELECT DISTINCT region FROM raw.mapeo_estados),
ventas AS (
    SELECT
        date_trunc('month', v.fecha)::date AS mes,
        dp.grupo,
        dc.region,
        SUM(v.precio)              AS ventas,
        COUNT(DISTINCT v.order_id) AS pedidos
    FROM bi.vw_fact_ventas v
    JOIN bi.vw_dim_producto dp USING (product_id)
    JOIN bi.vw_dim_cliente  dc USING (customer_id)
    WHERE v.fecha >= DATE '2017-01-01' AND v.fecha < DATE '2018-01-01'
    GROUP BY 1, 2, 3
)
SELECT
    m.mes,
    g.grupo,
    r.region,
    COALESCE(v.ventas, 0)  AS ventas_2017,
    COALESCE(v.pedidos, 0) AS pedidos_2017
FROM meses m
CROSS JOIN grupos g
CROSS JOIN regiones r
LEFT JOIN ventas v ON v.mes = m.mes AND v.grupo = g.grupo AND v.region = r.region
ORDER BY m.mes, g.grupo, r.region;

-- ---------------------------------------------------------- resumen mensual
-- Totales de control. El acumulado usa una función de ventana y debe coincidir
-- con [Ventas YTD] en Power BI.
CREATE VIEW bi.vw_resumen_mensual AS
WITH mensual AS (
    SELECT
        date_trunc('month', fecha)::date   AS mes,
        SUM(precio)                        AS ventas,
        SUM(flete)                         AS flete,
        COUNT(DISTINCT order_id)           AS pedidos,
        COUNT(*)                           AS partidas,
        COUNT(DISTINCT customer_unique_id) AS clientes_unicos
    FROM bi.vw_fact_ventas
    GROUP BY 1
)
SELECT
    mes,
    ventas,
    flete,
    pedidos,
    partidas,
    clientes_unicos,
    ROUND(ventas / NULLIF(pedidos, 0), 2) AS ticket_promedio,
    SUM(ventas) OVER (PARTITION BY EXTRACT(YEAR FROM mes) ORDER BY mes) AS ventas_ytd,
    LAG(ventas, 12) OVER (ORDER BY mes)                                 AS ventas_aa
FROM mensual
ORDER BY mes;
