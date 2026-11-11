# Medidas DAX

Las 38 medidas del modelo, agrupadas por carpeta, con su fórmula y su descripción. Se generan del modelo guardado en `ventas_vs_meta.SemanticModel`. Cada una se comprobó contra una consulta de `sql/04_validacion.sql`.

## Tres reglas que siguen estas medidas

- **Los blancos de DAX se comparan como cero.** Un filtro `<= 0` o `<= 2` sobre una columna con blancos los incluye. Por eso las medidas de logística filtran por la columna de texto `entrega` o por listas de valores (`IN { 1, 2 }`).
- **El año anterior se compara solo en los días con ventas.** Los datos terminan el 29 de agosto de 2018; la columna `dim_calendario[con_ventas]` evita comparar ocho meses de 2018 contra todo 2017.
- **La meta solo existe por mes, grupo y región.** `Meta` queda en blanco si se filtra por estado, categoría o vendedor, en lugar de repetir la meta total.

## 1 Base

### Ventas

Suma del precio de las partidas, sin flete. Excluye pedidos cancelados y unavailable.

```dax
Ventas =
SUM ( fact_ventas[precio] )
```

### Flete

Suma del flete de las partidas.

```dax
Flete =
SUM ( fact_ventas[flete] )
```

### Pedidos

Pedidos distintos con al menos una partida vendida.

```dax
Pedidos =
DISTINCTCOUNT ( fact_ventas[order_id] )
```

### Ticket promedio

Ventas entre pedidos.

```dax
Ticket promedio =
DIVIDE ( [Ventas], [Pedidos] )
```

### Artículos por pedido

Partidas entre pedidos.

```dax
Artículos por pedido =
DIVIDE ( COUNTROWS ( fact_ventas ), [Pedidos] )
```

### Clientes únicos

Personas distintas (customer_unique_id), no cuentas por pedido.

```dax
Clientes únicos =
DISTINCTCOUNT ( fact_ventas[customer_unique_id] )
```

## 2 Tiempo

### _Periodo con datos (auxiliar, oculta)

Auxiliar: verdadero si el periodo en contexto tiene días con ventas.

```dax
_Periodo con datos =
CALCULATE ( COUNTROWS ( dim_calendario ), dim_calendario[con_ventas] = TRUE () ) > 0
```

### Ventas YTD

Ventas acumuladas desde el 1 de enero del año en contexto. En blanco después del último día con ventas.

```dax
Ventas YTD =
IF ( [_Periodo con datos], TOTALYTD ( [Ventas], dim_calendario[fecha] ) )
```

### Ventas AA

Ventas del mismo periodo del año anterior, solo para los días que tienen ventas en el año actual.

```dax
Ventas AA =
CALCULATE (
    [Ventas],
    CALCULATETABLE (
        SAMEPERIODLASTYEAR ( dim_calendario[fecha] ),
        dim_calendario[con_ventas] = TRUE ()
    )
)
```

### Crecimiento vs AA %

Variación de ventas contra el mismo periodo del año anterior.

```dax
Crecimiento vs AA % =
DIVIDE ( [Ventas] - [Ventas AA], [Ventas AA] )
```

### Ventas móvil 3M

Ventas del mes en contexto y los dos anteriores.

```dax
Ventas móvil 3M =
IF (
    [_Periodo con datos],
    CALCULATE (
        [Ventas],
        DATESINPERIOD ( dim_calendario[fecha], MAX ( dim_calendario[fecha] ), -3, MONTH )
    )
)
```

## 3 Meta

### Meta

Meta mensual simulada (Metas_2018.xlsx). Solo existe por mes, grupo y región; en blanco si se filtra por estado, categoría o vendedor.

```dax
Meta =
IF (
    ISFILTERED ( dim_cliente ) || ISFILTERED ( dim_producto ) || ISFILTERED ( dim_vendedor ),
    BLANK (),
    SUM ( fact_metas[meta] )
)
```

### Meta YTD

Meta acumulada desde enero.

```dax
Meta YTD =
IF ( [_Periodo con datos], TOTALYTD ( [Meta], dim_calendario[fecha] ) )
```

### Cumplimiento %

Ventas entre meta.

```dax
Cumplimiento % =
DIVIDE ( [Ventas], [Meta] )
```

### Cumplimiento YTD %

Ventas YTD entre meta YTD.

```dax
Cumplimiento YTD % =
DIVIDE ( [Ventas YTD], [Meta YTD] )
```

### Brecha vs meta

Ventas menos meta. Negativo = debajo de meta.

```dax
Brecha vs meta =
IF ( NOT ISBLANK ( [Meta] ), [Ventas] - [Meta] )
```

### Brecha grupos debajo de meta

Suma de las brechas negativas por grupo. Los grupos sobre la meta no compensan a los de abajo.

```dax
Brecha grupos debajo de meta =
IF (
    NOT ISBLANK ( [Meta] ),
    SUMX ( VALUES ( dim_grupo[grupo] ), MIN ( [Brecha vs meta], 0 ) )
)
```

### Semáforo

Etiqueta del cumplimiento: En meta (100 % o más), Cerca (90 a 100 %), Lejos (menos de 90 %).

```dax
Semáforo =
SWITCH (
    TRUE (),
    ISBLANK ( [Cumplimiento %] ), BLANK (),
    [Cumplimiento %] >= 1, "En meta",
    [Cumplimiento %] >= 0.9, "Cerca",
    "Lejos"
)
```

### Color cumplimiento

Color hexadecimal para formato condicional. Rojo solo debajo de meta.

```dax
Color cumplimiento =
SWITCH (
    TRUE (),
    ISBLANK ( [Cumplimiento %] ), BLANK (),
    [Cumplimiento %] >= 1, "#1F3A5F",
    [Cumplimiento %] >= 0.9, "#E8A0A0",
    "#C0392B"
)
```

### Color texto cumplimiento

Color del texto sobre el fondo de Color cumplimiento: oscuro sobre el rojo claro (90 a 100 %), blanco en los demás casos.

```dax
Color texto cumplimiento =
SWITCH (
    TRUE (),
    ISBLANK ( [Cumplimiento %] ), BLANK (),
    [Cumplimiento %] >= 1, "#FFFFFF",
    [Cumplimiento %] >= 0.9, "#262626",
    "#FFFFFF"
)
```

## 4 Logística

### Pedidos entregados

Pedidos con estatus delivered.

```dax
Pedidos entregados =
CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[estatus] = "delivered" )
```

### Pedidos tarde

Pedidos entregados después de la fecha estimada.

```dax
Pedidos tarde =
CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[entrega] = "Tarde" )
```

### Entrega a tiempo %

Entregados a más tardar en la fecha estimada, entre entregados con fecha de entrega registrada.

```dax
Entrega a tiempo % =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[estatus] = "delivered", fact_pedidos[entrega] = "A tiempo" ),
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[estatus] = "delivered", fact_pedidos[entrega] IN { "A tiempo", "Tarde" } )
)
```

### Días de entrega prom

Días promedio de la compra a la entrega.

```dax
Días de entrega prom =
AVERAGE ( fact_pedidos[dias_entrega] )
```

### Calificación prom

Promedio de la reseña más reciente de cada pedido (1 a 5).

```dax
Calificación prom =
AVERAGE ( fact_pedidos[calificacion] )
```

### Calificación tarde vs a tiempo

Calificación de pedidos tarde menos la de pedidos a tiempo. Solo pedidos con fecha de entrega.

```dax
Calificación tarde vs a tiempo =
CALCULATE ( [Calificación prom], fact_pedidos[entrega] = "Tarde" )
    - CALCULATE ( [Calificación prom], fact_pedidos[entrega] = "A tiempo" )
```

### Cancelación %

Pedidos cancelados entre todos los pedidos.

```dax
Cancelación % =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[estatus] = "canceled" ),
    COUNTROWS ( fact_pedidos )
)
```

### Calificación prom por grupo

Versión por grupo de producto o vendedor: filtra los pedidos que tienen al menos una partida en contexto. Un pedido con productos de dos grupos cuenta en los dos.

```dax
Calificación prom por grupo =
CALCULATE ( [Calificación prom], TREATAS ( VALUES ( fact_ventas[order_id] ), fact_pedidos[order_id] ) )
```

### Entrega a tiempo % por grupo

Versión por grupo de producto o vendedor: filtra los pedidos que tienen al menos una partida en contexto. Un pedido con productos de dos grupos cuenta en los dos.

```dax
Entrega a tiempo % por grupo =
CALCULATE ( [Entrega a tiempo %], TREATAS ( VALUES ( fact_ventas[order_id] ), fact_pedidos[order_id] ) )
```

## 5 Qué pasa si

### % reseñas 1-2 tarde

Pedidos tarde con 1 o 2 estrellas, entre pedidos tarde con reseña.

```dax
% reseñas 1-2 tarde =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[entrega] = "Tarde", fact_pedidos[calificacion] IN { 1, 2 } ),
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[entrega] = "Tarde", fact_pedidos[calificacion] IN { 1, 2, 3, 4, 5 } )
)
```

### % reseñas 1-2 a tiempo

Pedidos a tiempo con 1 o 2 estrellas, entre pedidos a tiempo con reseña.

```dax
% reseñas 1-2 a tiempo =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[entrega] = "A tiempo", fact_pedidos[calificacion] IN { 1, 2 } ),
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[entrega] = "A tiempo", fact_pedidos[calificacion] IN { 1, 2, 3, 4, 5 } )
)
```

### Reseñas 1-2 evitables

Reseñas de 1 a 2 estrellas que se evitarían si esa parte de los pedidos tarde llegara a tiempo. Estimación.

```dax
Reseñas 1-2 evitables =
VAR mejora = SELECTEDVALUE ( 'Mejora entregas'[Mejora entregas], 0.5 )
RETURN
    [Pedidos tarde] * ( [% reseñas 1-2 tarde] - [% reseñas 1-2 a tiempo] ) * mejora
```

### Ventas recuperables

Estimación: reseñas evitadas por tasa de recompra por ticket promedio. Supone que un cliente con 1 a 2 estrellas no recompra.

```dax
Ventas recuperables =
VAR recompra = SELECTEDVALUE ( 'Recompra'[Recompra], 0.035 )
RETURN
    [Reseñas 1-2 evitables] * recompra * [Ticket promedio]
```

### % de la brecha recuperable

Ventas recuperables entre la brecha de los grupos debajo de meta.

```dax
% de la brecha recuperable =
DIVIDE ( [Ventas recuperables], ABS ( [Brecha grupos debajo de meta] ) )
```

## 6 Visuales

### % pedidos tarde

Pedidos tarde entre pedidos con fecha de entrega.

```dax
% pedidos tarde =
DIVIDE (
    [Pedidos tarde],
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[entrega] IN { "A tiempo", "Tarde" } )
)
```

### % de pedidos

Reparto de los pedidos con reseña por calificación, dentro de cada grupo de entrega. Para el histograma de la página 3.

```dax
% de pedidos =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_pedidos ), KEEPFILTERS ( fact_pedidos[calificacion] IN { 1, 2, 3, 4, 5 } ) ),
    CALCULATE ( COUNTROWS ( fact_pedidos ), fact_pedidos[calificacion] IN { 1, 2, 3, 4, 5 } )
)
```

### Cumplimiento de la región

Cumplimiento de la región a la que pertenece el estado. La meta no existe por estado. Para el tooltip del mapa.

```dax
Cumplimiento de la región =
CALCULATE (
    [Cumplimiento %],
    REMOVEFILTERS ( dim_cliente ),
    TREATAS ( VALUES ( dim_cliente[region] ), dim_region[region] )
)
```

### Pedidos tarde por vendedor

Pedidos tarde que incluyen partidas del vendedor en contexto.

```dax
Pedidos tarde por vendedor =
CALCULATE ( [Pedidos tarde], TREATAS ( VALUES ( fact_ventas[order_id] ), fact_pedidos[order_id] ) )
```
