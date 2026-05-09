# Arquitectura — multi-store-inventory-sync

## Tres triggers en un workflow

```
┌──────────────────────────┐    ┌──────────────────────────┐    ┌──────────────────────┐
│ Webhook: WooCommerce     │    │ Webhook: Odoo            │    │ Cron: Daily 03:00    │
│ POST /webhook/           │    │ POST /webhook/           │    │ ScheduleTrigger      │
│ sync-from-woo            │    │ sync-from-odoo           │    │                      │
└────────────┬─────────────┘    └────────────┬─────────────┘    └──────────┬───────────┘
             │                               │                             │
             ▼                               ▼                             ▼
       (Subflow A)                     (Subflow B)                  (Subflow C)
        WC → Odoo                       Odoo → WC                   Reconciliation
```

## Subflow A: WooCommerce → Odoo

```
[Webhook: WC]
    │
    ▼
[Idempotency: WC Event]      ← INSERT ON CONFLICT DO NOTHING RETURNING id
    │
    ▼
[WC: New?]──true────────────────────────────────────────────────────┐
    │                                                                ▼
    │                                                       [WC: Parse + SoT Filter]
    │                                                                │   (Code: extract sku/field/value,
    │                                                                │    decide if event should propagate)
    │                                                                ▼
    │                                                       [WC: Audit Received]
    │                                                                │   (status='received' or 'ignored_not_sot')
    │                                                                ▼
    │                                                       [WC: Should Propagate?]──false──→[Respond 200 (ignored)]
    │                                                                │
    │                                                                ▼
    │                                                    [WC→Odoo: Circuit Check]
    │                                                                │   (SELECT system_health WHERE name='odoo')
    │                                                                ▼
    │                                                    [Circuit OK?]──false──→[Queue: WAITING_FOR_TARGET]──→[Respond 202 queued]
    │                                                                │ true
    │                                                                ▼
    │                                                    [Apply: Odoo JSON-RPC]   (continueOnFail)
    │                                                                │
    │                                                                ▼
    │                                                    [Audit + Health update]   (status='applied'|'failed', failure counter ±)
    │                                                                │
    │                                                                ▼
    │                                                    [Respond 200 (applied)]
    │ false
    ▼
[Respond 200 (duplicate)]
```

## Subflow B: Odoo → WooCommerce

Mirror de Subflow A. Diferencias clave:

- Inbound: Odoo Automation rule con un `event_id` UUID generado por nosotros.
- Apply: PUT `WOO_BASE_URL/wp-json/wc/v3/products?sku=...` con HTTP Basic Auth (`consumer_key:consumer_secret`).
- Circuit breaker check va contra `system_health WHERE system_name = 'woocommerce'`.

## Subflow C: Daily Reconciliation

```
[Cron 03:00]
    │
    ▼
[Recon: Fetch WC Products]      ← GET /wp-json/wc/v3/products?per_page=100
    │
    ▼
[Recon: Fetch Odoo Products]    ← JSON-RPC product.product.search_read
    │
    ▼
[Recon: Compute Drift]          ← Code: builds drift_items[] for each kind:
    │                              { stock_drift, price_drift, missing_in_wc, missing_in_odoo }
    ▼
[Recon: Persist Run + Items]    ← One reconciliation_runs row + N drift_items
    │                              (uses jsonb_to_recordset for the bulk insert)
    ▼
[Recon: Insert Alert (if drift)]← Conditional INSERT into alerts (severity by drift count)
```

## Source-of-truth matrix

| Field   | SoT          | Inbound to non-SoT side does           | Inbound to SoT side does               |
|---------|--------------|----------------------------------------|----------------------------------------|
| stock   | Odoo         | order.created (WC) → decrement Odoo    | stock.move (Odoo) → propagate to WC    |
| stock   | Odoo         | product.update with stock change (WC)  | (n/a)                                  |
|         |              | → IGNORE (audit `ignored_not_sot`)     |                                        |
| price   | WooCommerce  | product.update (Odoo) for `list_price` | product.update (WC) → propagate to Odoo|
|         |              | → IGNORE                               |                                        |

## Circuit breaker — state machine

```
        ┌───────────┐
        │  CLOSED   │   normal operation, all events flow through
        └─────┬─────┘
              │  5 consecutive HTTP failures
              ▼
        ┌───────────┐
        │   OPEN    │   reject outbound, enqueue events to sync_queue
        └─────┬─────┘
              │  60 seconds elapsed (sweeper cron promotes)
              ▼
        ┌───────────┐
        │ HALF_OPEN │   allow one request through as a probe
        └──┬─────┬──┘
           │     │
       success  failure
           │     │
           ▼     ▼
       CLOSED  OPEN
```

The `Audit + Health update` Postgres node runs a **single SQL statement** that updates both the audit row and the system_health counters atomically. No race conditions between observation and decision.

## Datos que viajan entre nodos (Subflow A)

| Nodo                          | Output principal                                                              |
|-------------------------------|-------------------------------------------------------------------------------|
| Webhook: WooCommerce          | Raw WC payload + headers (incl. `x-wc-webhook-delivery-id`, `x-wc-webhook-topic`) |
| Idempotency: WC Event         | `{id}` sync_event UUID if new, empty otherwise                                |
| WC: Parse + SoT Filter        | `{sync_event_id, source, target, field, action, sku, value, should_propagate, ignored_reason}` |
| WC: Audit Received            | `{id}` audit row UUID                                                         |
| WC→Odoo: Circuit Check        | `{system_name, state, consecutive_failures, opened_at}`                       |
| WC→Odoo: Apply (JSON-RPC)     | Odoo response (`{result}` on success, `{error}` on failure)                   |
| WC→Odoo: Audit + Health       | `{state, consecutive_failures}` post-update                                   |
| Respond                       | `{status, sync_event_id, applied|queued|ignored}` to WC                       |

## Failure modes

| Failure                                   | Handling                                                                |
|-------------------------------------------|-------------------------------------------------------------------------|
| Duplicate webhook from WC/Odoo            | Idempotency Insert returns 0 rows → respond 200 silently                |
| Event for a non-SoT field                 | SoT Filter sets should_propagate=false → audit `ignored_not_sot`        |
| Target system slow (single timeout)       | continueOnFail keeps the flow → Audit logs `failed`, health counter ++  |
| Target system down (5+ consecutive fails) | system_health flips to OPEN → next events go to sync_queue              |
| Target recovers                           | Sweeper cron promotes OPEN → HALF_OPEN. First success → CLOSED          |
| Drainer behind                            | Reconciliation cron will catch the resulting drift the next morning     |
| Odoo UID rotated                          | Apply node returns auth error → audit failed → ops sees in alerts table |
| WC consumer_key revoked                   | HTTP 401 from Apply → same path, alert fires                            |
| Postgres down                             | Webhook nodes fail-fast → WC/Odoo will retry the webhook delivery       |

## Why not vector clocks / CRDTs / a queue broker (RabbitMQ/Kafka)

Considered alternatives:

- **Vector clocks** — robust under network partitions and out-of-order delivery. Overkill here: our two systems aren't peer nodes. Each field has a clear owner. The SoT filter + idempotency + last-write-wins covers the realistic conflict cases.
- **CRDTs** — same as above. Plus they require participating systems to support merge semantics, which WC/Odoo do not.
- **RabbitMQ / Kafka in front** — would replace `sync_queue` table. Adds infra ops (broker uptime, consumer groups, partition rebalancing). Postgres is already in the stack and the throughput here (orders/minute, not orders/second) doesn't need a broker. Migration path stays open: the audit table makes it easy to swap the queue for a broker later.
