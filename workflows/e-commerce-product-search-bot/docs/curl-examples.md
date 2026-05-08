# Curl examples — e-commerce-product-search-bot

> Reemplazá `https://your-n8n.example.com` con la URL de tu instancia n8n.
> El workflow expone el path `/webhook/acme-search`.

## 1. Búsqueda simple por categoría

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/acme-search \
  -H "Content-Type: application/json" \
  -d '{
    "query": "laptop gamer",
    "max_results": 4
  }'
```

**Response esperado** (campos clave):

```json
{
  "session_id": "session_1715183210123_abc123",
  "reply": "Encontré 3 laptops gamer que podrían interesarte:\n\n1. **ACME Predator X15** — USD 1499.00\n2. **ACME ROG Strix G16** — USD 1799.00\n3. **ACME Legion Pro** — USD 1399.00",
  "products": [
    { "id": 4521, "name": "ACME Predator X15", "price": "1499.00", "currency": "USD", "in_stock": true, "permalink": "..." },
    { "id": 4522, "name": "ACME ROG Strix G16", "price": "1799.00", "currency": "USD", "in_stock": true, "permalink": "..." },
    { "id": 4523, "name": "ACME Legion Pro",   "price": "1399.00", "currency": "USD", "in_stock": true, "permalink": "..." }
  ],
  "meta": {
    "query": "laptop gamer",
    "intent": "category_search",
    "provider": "openai",
    "latency_ms": 1840,
    "result_count": 3,
    "validation": {
      "mentioned_count": 3,
      "valid_count": 3,
      "invalid_count": 0,
      "hallucination_score": 0,
      "sanitized": false,
      "sanitization_reason": null,
      "threshold": 0.3
    }
  }
}
```

---

## 2. Búsqueda con filtro de precio en lenguaje natural

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/acme-search \
  -H "Content-Type: application/json" \
  -d '{
    "query": "monitor 4k menos de 500",
    "max_results": 3
  }'
```

El parser de Validate & Classify detecta `price_max: 500` desde "menos de 500" y lo aplica en Pre-filter.

**Response esperado** (recortado):

```json
{
  "reply": "Encontré 2 monitores 4K dentro de tu presupuesto:\n\n1. **ACME UltraSharp 27\"** — USD 449.00\n2. **ACME Vision Pro 32\"** — USD 489.00",
  "meta": {
    "query": "monitor 4k menos de 500",
    "intent": "category_search",
    "validation": { "hallucination_score": 0, "sanitized": false }
  }
}
```

---

## 3. Búsqueda que dispara sanitization (LLM alucinó)

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/acme-search \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "test-hallucination-001",
    "query": "auriculares bluetooth premium",
    "max_results": 4
  }'
```

**Caso típico:** el LLM responde mencionando un producto inventado ("ACME EarPods Pro X9") que no está en la API real. El post-procesador lo detecta y descarta la respuesta del LLM.

**Response esperado** (recortado):

```json
{
  "reply": "Encontré 4 productos que podrían interesarte:\n\n1. **ACME SoundCore Z3** — USD 89.00\n2. **ACME Bose QC35 II** — USD 299.00\n3. **ACME JBL Tune 770NC** — USD 119.00\n4. **ACME Sennheiser Momentum 4** — USD 349.00",
  "meta": {
    "validation": {
      "mentioned_count": 5,
      "valid_count": 4,
      "invalid_count": 1,
      "invalid_ids": ["99999"],
      "hallucination_score": 0.2,
      "sanitized": true,
      "sanitization_reason": "hallucination_threshold_exceeded"
    }
  }
}
```

Notar que `reply` es la respuesta **reconstruida desde datos reales**, no la del LLM. El campo `validation.invalid_ids` contiene el ID que se inventó el LLM.

---

## Postman collection

Importable desde [./postman-collection.json](./postman-collection.json) — incluye los 3 ejemplos anteriores con variables `{{base_url}}` y `{{webhook_path}}` parametrizadas.
