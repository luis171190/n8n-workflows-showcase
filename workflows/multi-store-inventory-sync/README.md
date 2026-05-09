# 🔄 Multi-store Inventory Sync — WooCommerce ↔ Odoo

> Sincronización bidireccional de stock + precio entre WooCommerce y Odoo, con source-of-truth por field, idempotencia cross-system, circuit breaker per-target, audit trail completo y reconciliación nightly. Tres triggers en un solo workflow.

## Problema

Un retailer multi-canal vende en su WooCommerce store y gestiona stock + compras en Odoo ERP. Si los dos sistemas no se sincronizan automáticamente:

- **Vendés stock que no tenés** (WC dice 10, Odoo tiene 0 porque alguien transfirió a otro depósito).
- **Mostrás precios viejos** (marketing actualizó WC, Odoo quedó con el precio anterior).
- **Cargás trabajo manual** (alguien copia/pega entre los dos sistemas todo el día).

Una sync naïve "actualizá todo en ambos lados" rompe rápido: dos sistemas se pisan mutuamente, una caída de uno multiplica los reintentos, un webhook duplicado descuenta stock dos veces, y nadie sabe quién cambió qué cuando hay drift.

Este workflow resuelve los 7 problemas concretos:

1. ¿Quién manda en cada field? → **Source of Truth por field**.
2. ¿Qué pasa con la latencia entre sistemas? → **Eventual consistency con SLA explícito**.
3. ¿Cómo resolvemos updates concurrentes? → **Conflict resolution: SoT priority + last-write-wins**.
4. ¿Y si llega el mismo webhook dos veces? → **Idempotencia compuesta `(source, event_id)`**.
5. ¿Cómo debuggeamos un drift después? → **Audit trail completo en SQL**.
6. ¿Y los drifts que igual escapan? → **Reconciliación nightly con drift report**.
7. ¿Y si Odoo se cae 1 hora? → **Circuit breaker per-target con queue**.

## Arquitectura

```
┌───────────────────┐    ┌───────────────────┐    ┌────────────────────┐
│ Webhook: WC       │    │ Webhook: Odoo     │    │ Cron: Daily 03:00  │
│ /sync-from-woo    │    │ /sync-from-odoo   │    │ Reconciliation     │
└────────┬──────────┘    └────────┬──────────┘    └─────────┬──────────┘
         │                        │                         │
         ▼                        ▼                         ▼
   Idempotency             Idempotency              Fetch WC + Odoo
         │                        │                         │
         ▼                        ▼                         ▼
   SoT Filter              SoT Filter                Compute drift
         │                        │                         │
         ▼                        ▼                         ▼
   Circuit Check           Circuit Check          Persist runs + items
         │                        │                         │
         ▼                        ▼                         ▼
   Apply (Odoo RPC)        Apply (WC REST)        Insert alert if drift
         │                        │
         ▼                        ▼
   Audit + Health          Audit + Health
```

Diagrama detallado, datos por nodo, state machine del circuit breaker y failure modes en [`docs/architecture.md`](./docs/architecture.md).

## Stack

- **n8n** (self-hosted, v1.x)
- **WooCommerce REST API** (`/wp-json/wc/v3/products`) — HTTP Basic Auth con `consumer_key:consumer_secret`
- **Odoo JSON-RPC** (`/jsonrpc`) — `execute_kw` con UID + password
- **Postgres** — sync_events, sync_audit, sync_queue, system_health, reconciliation_runs, reconciliation_drift_items, alerts (schema en `sql/001_inventory_sync_schema.sql`)

## Decisiones técnicas destacadas

### 1. Source of Truth por field (defendible)

Cada sistema **manda** en la dimensión donde es la herramienta correcta para el equipo dueño:

| Field   | SoT          | Razón                                                                                          |
|---------|--------------|------------------------------------------------------------------------------------------------|
| stock   | **Odoo**     | El ERP registra movimientos físicos: compras, ventas, devoluciones, transferencias entre depósitos. WC ve solo lo que se vendió ahí. |
| price   | **WooCommerce** | Marketing/comercial trabajan en WC: promos, A/B testing, schedule de campañas. Odoo es para precios "lista", no operacionales. |
| content | **WooCommerce** | Descripciones, imágenes, SEO — mismo equipo, misma herramienta.                              |
| SKU     | **Odoo**     | El alta formal del producto pasa por el ERP (con purchase orders, supply chain, etc.).         |

**Implementación**: el Code node `WC: Parse + SoT Filter` (y su mirror Odoo) decide `should_propagate=true|false` según `(source, field)`. Si es false, **el evento se loguea con `status='ignored_not_sot'` y se devuelve 200 con `reason`** — no se llama a la API target.

Esto evita que un edit manual en el lado equivocado contamine la SoT. Si alguien cambia stock directamente en WC admin, el evento se ignora; la próxima reconciliation lo va a corregir.

### 2. Eventual consistency con SLA explícito

| Path                              | SLA típico        |
|-----------------------------------|-------------------|
| Webhook directo + circuit CLOSED  | < 5 segundos      |
| Webhook + retry transitorio       | < 30 segundos     |
| Circuit OPEN + queue + drainer    | < 5 minutos       |
| Drift que escapó al live sync     | < 24h (next recon)|

El SLA worst-case son las 24h entre reconciliations — es deliberado: si algo se desvía y nadie está mirando, la primera oportunidad de detección es la próxima madrugada. Empresas con datos críticos (stock que mueve millones de dólares) bajan el cron a cada hora; el patrón es el mismo.

### 3. Conflict resolution

**Strategy: SoT priority + last-write-wins.**

```
resolve(field, source, value, timestamp):
  if source == SoT[field]:
      apply_atomic()              # SoT always wins, last write wins among SoT events
  else:
      audit_log('ignored_not_sot') # non-SoT events never propagate
```

**Por qué no vector clocks ni CRDTs**: nuestros dos sistemas no son peer nodes en una red distribuida — son dataset tipados con dueño claro por field. Vector clocks brillan cuando todos los nodos pueden modificar el mismo dato y la red puede particionarse; acá la partición se traduce en circuit OPEN + queue, que es más simple y resuelve el caso real.

**Por qué last-write-wins es seguro acá**: dos eventos que tocan la misma SoT field en milisegundos, ambos llegan al workflow. La tabla `sync_events` los serializa por `received_at` UNIQUE; los Apply HTTPs corren en orden de llegada. Si el segundo gana, eso es exactamente lo deseado (la versión más reciente).

### 4. Idempotencia cross-system

**Compound UNIQUE** `(source_system, source_event_id)`:

```sql
INSERT INTO sync_events (source_system, source_event_id, raw_payload)
VALUES ($1, $2, $3)
ON CONFLICT (source_system, source_event_id) DO NOTHING
RETURNING id;
```

Si el INSERT no devuelve fila → el evento ya fue procesado → respondemos 200 silently antes de tocar nada más.

**Por qué compuesto** y no solo `event_id`: WC y Odoo emiten event_ids en namespaces independientes. Un `delivery_id=001` de WC no debe colisionar con un `event_id=001` de Odoo. El compound UNIQUE permite que ambos coexistan.

**Origen del event_id**:

- **WC**: header `X-WC-Webhook-Delivery-ID` (lo asigna el shipper de WC, único por entrega).
- **Odoo**: en la Automation rule outbound, generamos un UUID y lo embebemos en el body. La rule de Odoo nunca dispara el mismo UUID dos veces.

### 5. Audit trail completo

Tabla `sync_audit` append-only. Una fila por cada decisión del workflow:

```sql
sync_audit (
    sync_event_id, source, target, sku, field, action,
    status,           -- received | ignored_not_sot | queued | applied | failed
    before_value, after_value,
    error_message,
    created_at
)
```

**Power query**: "¿qué pasó con el SKU X las últimas 48h?"

```sql
SELECT created_at, source_system, target_system, field, action, status, error_message
FROM   sync_audit
WHERE  sku = 'ACME-LAPTOP-15' AND created_at > NOW() - INTERVAL '48 hours'
ORDER  BY created_at DESC;
```

Esto es lo que se le manda a soporte cuando un cliente dice "vendí 5 y mi stock dice -2". Reconstruís el historial en una query.

### 6. Reconciliación nightly con drift detection

Cron 03:00. Pasos en `Subflow C`:

1. Fetch all WC products (paginado, `per_page=100`).
2. Fetch all Odoo products vía JSON-RPC `search_read`.
3. Compute drift por SKU:
   - `stock_drift` — `wc.stock !== odoo.stock`
   - `price_drift` — `|wc.price - odoo.price| > 0.01`
   - `missing_in_wc` / `missing_in_odoo`
4. INSERT `reconciliation_runs` (1 fila summary) + INSERT batch `reconciliation_drift_items` (N filas detail).
5. INSERT `alerts` con severity proporcional al drift count (`info` < 10, `warning` < 50, `critical` ≥ 50).

**Auto-fix opt-in**: env var `RECONCILIATION_AUTO_FIX=true|false`. Default `false` — para showcase y onboarding querés ver primero qué te corrige antes de dejarlo automático.

### 7. Circuit breaker per-target

Tabla `system_health` con state machine clásico:

```
CLOSED ── 5 fails ──▶ OPEN ── 60s ──▶ HALF_OPEN ─┬── success ──▶ CLOSED
                                                  └── fail ─────▶ OPEN
```

**Pre-flight check**: cada Apply HTTP es precedido por un `Circuit Check` Postgres que lee `system_health WHERE system_name`. Si el state es `OPEN`, el evento se mete a `sync_queue` con `status='WAITING_FOR_TARGET'` y se devuelve **HTTP 202** al webhook (acknowledged pero no aplicado todavía).

**Health update**: el nodo `Audit + Health` corre **una sola query SQL** que actualiza tanto el audit row como los counters de `system_health` atómicamente:

```sql
WITH applied AS (
    UPDATE sync_audit SET status = ..., error_message = ...
    WHERE sync_event_id = $1
)
UPDATE system_health
SET    state = CASE WHEN $success THEN 'CLOSED' ELSE state END,
       consecutive_failures = CASE WHEN $success THEN 0 ELSE consecutive_failures + 1 END,
       opened_at = CASE WHEN NOT $success AND consecutive_failures + 1 >= 5 THEN NOW() ELSE opened_at END
WHERE system_name = $target;
```

Sin race entre observación y decisión.

**Promoción OPEN → HALF_OPEN**: un sweeper cron (cada 30s) corre:

```sql
UPDATE system_health SET state='HALF_OPEN'
WHERE state='OPEN' AND opened_at < NOW() - INTERVAL '60 seconds';
```

## Setup

### 1. Variables de entorno

Copiar `.env.example` a `.env.local` y completar.

| Var | Descripción |
|---|---|
| `WOO_BASE_URL` | URL de tu WooCommerce (sin trailing slash) |
| `ODOO_BASE_URL`, `ODOO_DATABASE`, `ODOO_UID`, `ODOO_PASSWORD` | Credenciales Odoo (UID se obtiene una vez via `/web/session/authenticate`) |
| `RECONCILIATION_AUTO_FIX` | `true`/`false` — controla si recon corrige o solo reporta |

### 2. Base de datos

```bash
psql $DATABASE_URL -f sql/001_inventory_sync_schema.sql
```

Crea las 7 tablas + seed inicial de `system_health` con WC y Odoo en `CLOSED`.

### 3. Credenciales en n8n

| Credencial | Tipo | Nombre exacto |
|---|---|---|
| Postgres | `postgres` | `inventory_db` |
| WooCommerce HTTP Basic | `httpBasicAuth` | `wc_consumer_key_secret` (username = ck_..., password = cs_...) |

Después del import, abrí los nodos Postgres y HTTP que tienen `REPLACE_WITH_*` y reasignales las credenciales reales.

### 4. Configurar webhooks

- **WooCommerce**: Settings → Advanced → Webhooks → New
  - Topic: `Order created`, `Product updated`
  - Delivery URL: `https://tu-n8n.example.com/webhook/sync-from-woo`
  - Secret: (opcional pero recomendado, validalo en un nodo Code antes del Idempotency)
- **Odoo**: Settings → Technical → Automation Rules → New
  - Trigger: On Update of `product.product` field `qty_available`
  - Action: HTTP request → `https://tu-n8n.example.com/webhook/sync-from-odoo`
  - Body: incluir `event_id` UUID + sku + field + value

### 5. Sweepers

| Sweeper | Frecuencia | Query |
|---|---|---|
| Promote OPEN → HALF_OPEN | 30s | `UPDATE system_health SET state='HALF_OPEN' WHERE state='OPEN' AND opened_at < NOW() - INTERVAL '60 seconds';` |
| GAVE_UP queue items | Hourly | `UPDATE sync_queue SET status='GAVE_UP' WHERE status IN ('WAITING_FOR_TARGET','RETRY') AND retry_count >= 10;` |
| Drop sync_events viejos | Nightly | `DELETE FROM sync_events WHERE received_at < NOW() - INTERVAL '30 days';` |
| Drop reconciliation_runs viejos | Nightly | `DELETE FROM reconciliation_runs WHERE started_at < NOW() - INTERVAL '90 days';` (cascadea drift_items) |

### 6. Importar y activar

n8n UI → Workflows → Import from File → seleccionar `workflow.json`. Reasignar credenciales. Activar.

## Examples

6 ejemplos completos en [`docs/curl-examples.md`](./docs/curl-examples.md), Postman collection con 6 requests + tests automatizados en [`docs/postman-collection.json`](./docs/postman-collection.json).

| # | Escenario | Demuestra |
|---|---|---|
| 1 | WC `order.created` con SKU | Happy path: SoT match + circuit CLOSED + apply Odoo |
| 2 | WC stock change | SoT filter bloquea: respond `ignored` |
| 3 | WC price change | SoT filter permite: respond `applied` |
| 4 | Odoo `qty_available` change | Reverse direction (Odoo → WC) |
| 5 | Replay del evento 1 | Idempotency short-circuit |
| 6 | Circuit OPEN simulado | Queue + 202 response |

## Switching language / providers

Este workflow no usa LLM (no hay un assistant generando texto), por lo que no aplican `BOT_LANG` ni `LLM_PROVIDER`.

## Extensión: drainer cron

El JSON contiene la queue (`sync_queue`) pero **no incluye el drainer**. Agregar:

1. Nuevo Schedule Trigger cada 1 minuto.
2. Postgres SELECT: `SELECT * FROM sync_queue WHERE status IN ('WAITING_FOR_TARGET','RETRY') AND scheduled_at <= NOW() ORDER BY scheduled_at LIMIT 50`.
3. Por cada row: chequear `system_health[target]`. Si está CLOSED/HALF_OPEN, retry el Apply (mismo HTTP node que el live path). Si éxito, UPDATE status='APPLIED'. Si fail, retry_count++, last_error, scheduled_at = NOW() + INTERVAL '1 minute' * retry_count^2 (exponential backoff).
4. Si retry_count >= 10, status='GAVE_UP' + insert alert.

Lo dejé afuera del JSON principal para mantenerlo enfocado en los 7 conceptos. Es ~6 nodos extras siguiendo el patrón demostrado.

## Estructura de archivos

```
multi-store-inventory-sync/
├── README.md
├── workflow.json                          # 42 nodos (36 funcionales + 6 sticky notes), 3 triggers
├── .env.example
├── sql/
│   └── 001_inventory_sync_schema.sql      # 7 tablas + indices + seed system_health
└── docs/
    ├── architecture.md                    # diagrama detallado + state machine + failure modes
    ├── curl-examples.md                   # 6 escenarios end-to-end
    └── postman-collection.json            # 6 requests + 13 tests automatizados
```

---

[← Volver al índice](../../README.md)
