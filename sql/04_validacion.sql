-- =============================================================================
-- 04_validacion.sql · Totales de control para cuadrar cada medida DAX
-- Cada bloque indica contra qué medida de Power BI se compara.
-- Regla del checklist: [Ventas] total en Power BI = bloque 1, al centavo.
-- =============================================================================

-- 1. Base: [Ventas], [Flete], [Pedidos], [Ticket promedio],
--    [Artículos por pedido], [Clientes únicos]  (sin filtros)
SELECT
    SUM(precio)                                                  AS ventas,
    SUM(flete)                                                   AS flete,
    COUNT(DISTINCT order_id)                                     AS pedidos,
    ROUND(SUM(precio) / COUNT(DISTINCT order_id), 4)             AS ticket_promedio,
    ROUND(COUNT(*)::numeric / COUNT(DISTINCT order_id), 4)       AS articulos_por_pedido,
    COUNT(DISTINCT customer_unique_id)                           AS clientes_unicos
FROM bi.vw_fact_ventas;

-- 2. [Ventas] por año  (segmenta por año en Power BI)
SELECT EXTRACT(YEAR FROM fecha)::int AS anio, SUM(precio) AS ventas, COUNT(DISTINCT order_id) AS pedidos
FROM bi.vw_fact_ventas
GROUP BY 1 ORDER BY 1;

-- 3. Inteligencia de tiempo: [Ventas], [Ventas YTD], [Ventas AA],
--    [Crecimiento vs AA %] por mes
SELECT
    mes,
    ventas,
    ventas_ytd,
    ventas_aa,
    ROUND((ventas - ventas_aa) / NULLIF(ventas_aa, 0), 4) AS crecimiento_vs_aa
FROM bi.vw_resumen_mensual
ORDER BY mes;

-- 4. [Ventas móvil 3M]: suma del mes y los dos anteriores
SELECT
    mes,
    SUM(ventas) OVER (ORDER BY mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS ventas_movil_3m
FROM bi.vw_resumen_mensual
ORDER BY mes;

-- 5. [Ventas] por grupo y región, ene-ago 2018  (matriz de la página 2)
SELECT dp.grupo, dc.region, SUM(v.precio) AS ventas_2018
FROM bi.vw_fact_ventas v
JOIN bi.vw_dim_producto dp USING (product_id)
JOIN bi.vw_dim_cliente  dc USING (customer_id)
WHERE v.fecha >= DATE '2018-01-01'
GROUP BY 1, 2 ORDER BY 1, 2;

-- 6. Logística: [Pedidos entregados], [Entrega a tiempo %],
--    [Días de entrega prom], [Calificación prom], [Cancelación %]
--    Ojo: en DAX, BLANK <= 0 es verdadero. Los entregados sin fecha de entrega
--    contarían como "a tiempo"; por eso aquí se filtran con IS NOT NULL y la
--    medida DAX debe excluir los blancos de dias_retraso.
SELECT
    COUNT(*) FILTER (WHERE estatus = 'delivered')                              AS pedidos_entregados,
    ROUND(COUNT(*) FILTER (WHERE estatus = 'delivered' AND dias_retraso <= 0)::numeric
        / NULLIF(COUNT(*) FILTER (WHERE estatus = 'delivered' AND dias_retraso IS NOT NULL), 0), 4)
                                                                               AS entrega_a_tiempo_pct,
    ROUND(AVG(dias_entrega), 4)                                                AS dias_entrega_prom,
    ROUND(AVG(calificacion), 4)                                                AS calificacion_prom,
    ROUND(COUNT(*) FILTER (WHERE estatus = 'canceled')::numeric / COUNT(*), 4) AS cancelacion_pct
FROM bi.vw_fact_pedidos;

-- 7. [Calificación tarde vs a tiempo]: el número central del hallazgo
SELECT
    entrega,
    COUNT(*)                    AS pedidos,
    ROUND(AVG(calificacion), 4) AS calificacion_prom,
    ROUND(COUNT(*) FILTER (WHERE calificacion <= 2)::numeric
        / NULLIF(COUNT(calificacion), 0), 4) AS pct_calificacion_1_2
FROM bi.vw_fact_pedidos
WHERE entrega IS NOT NULL
GROUP BY entrega;

-- 8. Entrega y calificación por región  (página 3)
SELECT
    dc.region,
    COUNT(*)                                                         AS pedidos,
    ROUND(AVG(p.dias_entrega), 2)                                    AS dias_entrega_prom,
    ROUND(COUNT(*) FILTER (WHERE p.dias_retraso <= 0)::numeric
        / NULLIF(COUNT(p.dias_retraso), 0), 4)                       AS entrega_a_tiempo_pct,
    ROUND(AVG(p.calificacion), 4)                                    AS calificacion_prom
FROM bi.vw_fact_pedidos p
JOIN bi.vw_dim_cliente dc USING (customer_id)
WHERE p.estatus = 'delivered'
GROUP BY 1 ORDER BY 1;

-- 9. Integridad: todo debe dar 0
SELECT 'partidas con producto fuera de dim_producto' AS chequeo, COUNT(*) AS n
  FROM bi.vw_fact_ventas v WHERE NOT EXISTS (SELECT 1 FROM bi.vw_dim_producto d WHERE d.product_id = v.product_id)
UNION ALL
SELECT 'partidas con vendedor fuera de dim_vendedor', COUNT(*)
  FROM bi.vw_fact_ventas v WHERE NOT EXISTS (SELECT 1 FROM bi.vw_dim_vendedor d WHERE d.seller_id = v.seller_id)
UNION ALL
SELECT 'clientes sin región', COUNT(*) FROM bi.vw_dim_cliente WHERE region IS NULL
UNION ALL
SELECT 'pedidos duplicados en fact_pedidos', COUNT(*) - COUNT(DISTINCT order_id) FROM bi.vw_fact_pedidos
UNION ALL
SELECT 'diferencia base_2017 vs ventas 2017 (centavos)',
       ROUND(100 * ((SELECT SUM(ventas_2017) FROM bi.vw_base_2017)
                  - (SELECT SUM(precio) FROM bi.vw_fact_ventas WHERE fecha < DATE '2018-01-01')))::bigint;

-- 11. Recompra según la calificación del primer pedido (sustenta el parámetro
--     "Recompra" de la página 4). Solo clientes cuyo primer pedido fue antes de
--     jun 2018, para dejar al menos 3 meses de ventana para recomprar.
WITH p AS (
    SELECT c.customer_unique_id, f.order_id, f.fecha, f.calificacion, f.valor_pedido,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id ORDER BY f.fecha, f.order_id) AS n
    FROM bi.vw_fact_pedidos f
    JOIN bi.vw_dim_cliente c USING (customer_id)
    WHERE f.estatus NOT IN ('canceled', 'unavailable')
),
primera AS (SELECT * FROM p WHERE n = 1 AND fecha <= DATE '2018-05-31'),
despues AS (SELECT customer_unique_id, SUM(valor_pedido) AS valor_post FROM p WHERE n > 1 GROUP BY 1)
SELECT
    CASE WHEN pr.calificacion <= 2 THEN '1-2'
         WHEN pr.calificacion >= 3 THEN '3-5'
         ELSE 'sin reseña' END                                  AS calificacion_primer_pedido,
    COUNT(*)                                                    AS clientes,
    ROUND(AVG((d.customer_unique_id IS NOT NULL)::int), 4)      AS tasa_recompra
FROM primera pr
LEFT JOIN despues d USING (customer_unique_id)
GROUP BY 1 ORDER BY 1;

-- 12. Medidas de la página 4 para 2018, con Mejora = 100 %.
--     [Reseñas 1-2 evitables], [Ventas recuperables] con Recompra = 100 % y 3.5 %,
--     [Brecha grupos debajo de meta] y el % de la brecha que se recupera.
WITH p AS (SELECT * FROM bi.vw_fact_pedidos WHERE fecha >= DATE '2018-01-01'),
insumos AS (
    SELECT
        COUNT(*) FILTER (WHERE entrega = 'Tarde') AS pedidos_tarde,
        COUNT(*) FILTER (WHERE entrega = 'Tarde' AND calificacion <= 2)::numeric
            / COUNT(calificacion) FILTER (WHERE entrega = 'Tarde')    AS pct12_tarde,
        COUNT(*) FILTER (WHERE entrega = 'A tiempo' AND calificacion <= 2)::numeric
            / COUNT(calificacion) FILTER (WHERE entrega = 'A tiempo') AS pct12_a_tiempo
    FROM p
),
ticket AS (
    SELECT SUM(precio) / COUNT(DISTINCT order_id) AS ticket
    FROM bi.vw_fact_ventas WHERE fecha >= DATE '2018-01-01'
),
metas AS (
    SELECT grupo, SUM(ROUND(base * CASE WHEN grupo = 'Belleza y salud' THEN 1.30 ELSE 1.20 END, 2)) * 8 AS meta
    FROM (SELECT grupo, region, AVG(ventas_2017) AS base FROM bi.vw_base_2017
          WHERE mes BETWEEN DATE '2017-09-01' AND DATE '2017-12-01' GROUP BY 1, 2) b
    GROUP BY 1
),
ventas AS (
    SELECT dp.grupo, SUM(v.precio) AS ventas
    FROM bi.vw_fact_ventas v JOIN bi.vw_dim_producto dp USING (product_id)
    WHERE v.fecha >= DATE '2018-01-01' GROUP BY 1
),
brecha AS (SELECT SUM(LEAST(ventas - meta, 0)) AS brecha_debajo FROM metas JOIN ventas USING (grupo))
SELECT
    ROUND(i.pedidos_tarde * (i.pct12_tarde - i.pct12_a_tiempo), 2)                         AS resenas_12_evitables,
    ROUND(i.pedidos_tarde * (i.pct12_tarde - i.pct12_a_tiempo) * t.ticket, 2)              AS recuperables_recompra_100,
    ROUND(i.pedidos_tarde * (i.pct12_tarde - i.pct12_a_tiempo) * t.ticket * 0.035, 2)      AS recuperables_recompra_3_5,
    ROUND(b.brecha_debajo, 2)                                                               AS brecha_grupos_debajo,
    ROUND(i.pedidos_tarde * (i.pct12_tarde - i.pct12_a_tiempo) * t.ticket / ABS(b.brecha_debajo), 4)         AS pct_brecha_recompra_100,
    ROUND(i.pedidos_tarde * (i.pct12_tarde - i.pct12_a_tiempo) * t.ticket * 0.035 / ABS(b.brecha_debajo), 4) AS pct_brecha_recompra_3_5
FROM insumos i, ticket t, brecha b;

-- 10. Categorías que cayeron en "Otros" por no estar en el mapeo
--     (debe salir vacío; si no, agrégalas a data/mapeos/mapeo_categorias.csv)
SELECT p.categoria, COUNT(*) AS productos
FROM stg.productos p
WHERE NOT EXISTS (SELECT 1 FROM raw.mapeo_categorias m WHERE m.categoria = p.categoria)
GROUP BY 1 ORDER BY 2 DESC;
