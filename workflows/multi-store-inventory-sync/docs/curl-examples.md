# Curl examples — multi-store-inventory-sync

> Replace `https://your-n8n.example.com` with your n8n instance.
> Two webhook paths: `/webhook/sync-from-woo` and `/webhook/sync-from-odoo`.

These examples simulate webhooks from WooCommerce and Odoo without the real systems wired up. Useful for unit-testing the workflow logic, the SoT filter, idempotency, and circuit breaker.

## 1. WooCommerce order.created → reduce stock in Odoo

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/sync-from-woo \
  -H "Content-Type: application/json" \
  -H "x-wc-webhook-topic: order.created" \
  -H "x-wc-webhook-delivery-id: WC_DELIVERY_001" \
  -d '{
    "id": 12345,
    "status": "processing",
    "line_items": [
      { "sku": "ACME-LAPTOP-15", "quantity": 1, "name": "ACME Laptop 15\"" },
      { "sku": "ACME-MOUSE-X1",  "quantity": 2, "name": "ACME Mouse X1" }
    ]
  }'
```

**Response (HTTP 200):**

```json
{ "status": "ok", "sync_event_id": "...uuid...", "applied": true }
```

**Side-effects:**
- 1 row in `sync_events`, 2 rows in `sync_audit` (one per line item, both `applied`).
- 2 JSON-RPC calls to Odoo decrementing stock.

---

## 2. WooCommerce product.update with stock change → IGNORED (Odoo is SoT)

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/sync-from-woo \
  -H "Content-Type: application/json" \
  -H "x-wc-webhook-topic: product.updated" \
  -H "x-wc-webhook-delivery-id: WC_DELIVERY_002" \
  -d '{
    "id": 9001,
    "sku": "ACME-LAPTOP-15",
    "_stock_changed": true,
    "stock_quantity": 50
  }'
```

**Response:**

```json
{ "status": "ignored", "reason": "odoo_is_sot_for_stock" }
```

**Side-effects:**
- 1 row in `sync_events`, 1 row in `sync_audit` with `status='ignored_not_sot'`.
- No HTTP call to Odoo. Odoo is the source of truth for stock; we don't propagate stock changes from WC. If a human edited stock directly in the WC admin, the next reconciliation run will surface the drift and overwrite WC with the Odoo value.

---

## 3. WooCommerce product.update with price change → propagate to Odoo

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/sync-from-woo \
  -H "Content-Type: application/json" \
  -H "x-wc-webhook-topic: product.updated" \
  -H "x-wc-webhook-delivery-id: WC_DELIVERY_003" \
  -d '{
    "id": 9001,
    "sku": "ACME-LAPTOP-15",
    "_price_changed": true,
    "regular_price": "1299.00"
  }'
```

**Response:**

```json
{ "status": "ok", "sync_event_id": "...uuid...", "applied": true }
```

WC is SoT for price → propagate to Odoo as `list_price` update.

---

## 4. Odoo stock.move → propagate to WC

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/sync-from-odoo \
  -H "Content-Type: application/json" \
  -d '{
    "event_id": "ODOO_EVT_2026_05_08_001",
    "model": "product.product",
    "operation": "set",
    "sku": "ACME-LAPTOP-15",
    "field": "qty_available",
    "value": 47
  }'
```

**Response:**

```json
{ "status": "ok", "sync_event_id": "...uuid...", "applied": true }
```

Odoo is SoT for stock → PUT to WC `/wp-json/wc/v3/products?sku=ACME-LAPTOP-15` with `stock_quantity: 47`.

---

## 5. Idempotency replay (same delivery id)

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/sync-from-woo \
  -H "Content-Type: application/json" \
  -H "x-wc-webhook-topic: order.created" \
  -H "x-wc-webhook-delivery-id: WC_DELIVERY_001" \
  -d '{ "id": 12345, "line_items": [] }'
```

**Response:**

```json
{ "status": "already_processed" }
```

Short-circuits before any side-effect. The first delivery already inserted into `sync_events` with this `delivery_id`.

---

## 6. Circuit breaker OPEN → event queued

Simulate Odoo being down by manually flipping the state in `system_health`:

```sql
UPDATE system_health
SET state = 'OPEN', consecutive_failures = 5, opened_at = NOW()
WHERE system_name = 'odoo';
```

Then send a WC webhook:

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/sync-from-woo \
  -H "Content-Type: application/json" \
  -H "x-wc-webhook-topic: order.created" \
  -H "x-wc-webhook-delivery-id: WC_DELIVERY_004" \
  -d '{ "id": 12399, "line_items": [{"sku":"ACME-LAPTOP-15","quantity":1}] }'
```

**Response (HTTP 202):**

```json
{ "status": "queued", "sync_event_id": "...uuid...", "reason": "target_circuit_open" }
```

Reset the breaker once Odoo is back:

```sql
UPDATE system_health SET state='CLOSED', consecutive_failures=0, opened_at=NULL
WHERE system_name='odoo';
```

A drainer cron (extension — see README) will sweep `sync_queue` and re-apply the queued events.

---

## Inspect audit trail for one SKU

```sql
SELECT created_at, source_system, target_system, field, action, status, error_message
FROM   sync_audit
WHERE  sku = 'ACME-LAPTOP-15'
ORDER  BY created_at DESC
LIMIT  20;
```

This is the moneymaker for debugging. Every mutation passing through the workflow leaves a trace.

---

## Trigger reconciliation manually (instead of waiting until 03:00)

In n8n UI: open the workflow, click on `Cron: Daily 03:00` node, then **"Execute Node"**.

The Code node `Recon: Compute Drift` will return a JSON like:

```json
{
  "run_started_at": "2026-05-08T...",
  "total_skus_checked": 412,
  "stock_drift_count": 3,
  "price_drift_count": 0,
  "missing_count": 1,
  "auto_fix": false,
  "drift_items": [
    { "sku": "ACME-LAPTOP-15", "kind": "stock_drift", "wc": 50, "odoo": 47, "diff": 3 },
    { "sku": "ACME-MOUSE-X1",  "kind": "stock_drift", "wc": 100, "odoo": 98, "diff": 2 },
    { "sku": "ACME-CABLE-USB", "kind": "missing_in_odoo", "wc": { "stock": 200, "price": 9.99 }, "odoo": null }
  ]
}
```

A row in `reconciliation_runs` + 3 in `reconciliation_drift_items` get inserted, plus an `alerts` row of severity `info` (>0 drift but <10).

---

## Postman collection

[./postman-collection.json](./postman-collection.json) — 6 requests with automated tests covering: SoT filter (propagate vs ignore), idempotency, circuit breaker behavior, and audit assertions.
