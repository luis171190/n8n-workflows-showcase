# 🔄 Multi-store Inventory Sync

> Sincronizacion bidireccional de stock entre WooCommerce y Odoo via webhooks + JSON-RPC.

🚧 **En construccion** — workflow en desarrollo. Volve pronto.

## Que hara cuando este listo

- Detectara cambios de stock/precio en WooCommerce (webhook saliente).
- Replicara los cambios a Odoo (`stock.move` / `product.template`) via JSON-RPC.
- Detectara cambios en Odoo (cron polling) y los replicara a WooCommerce.
- Cola anti-duplicacion en Postgres + reconciliacion nocturna.

## Stack previsto

n8n · WooCommerce REST API · Odoo JSON-RPC · Postgres (cola/log)

---

[← Volver al indice](../../README.md)
