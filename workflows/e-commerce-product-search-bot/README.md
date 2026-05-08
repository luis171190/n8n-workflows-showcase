# 🛒 E-commerce Product Search Bot

> Chatbot de busqueda de productos para WooCommerce con OpenAI + post-procesador anti-hallucination.

🚧 **En construccion** — workflow en desarrollo. Volve pronto.

## Que hara cuando este listo

- Recibira mensajes de texto del cliente (intencion: buscar producto, marca, categoria, rango de precios).
- Consultara la **WooCommerce Store API** de la tienda demo (ACME Store).
- Aplicara post-procesado: filtrara por stock, precio, y elimina hallucinations del LLM (productos inventados).
- Devolvera resultados al frontend con marcador estructurado JSON que el widget renderiza como cards de producto.

## Stack previsto

n8n · OpenAI GPT-4 · WooCommerce Store API · JavaScript en Code nodes

---

[← Volver al indice](../../README.md)
