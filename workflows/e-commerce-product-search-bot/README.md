# 🛒 E-commerce Product Search Bot

> Chatbot de búsqueda de productos para WooCommerce con LLM intercambiable (OpenAI / Anthropic) y post-procesador anti-hallucination de 4 sub-componentes.

## Problema

Los chatbots de e-commerce que delegan la respuesta directamente al LLM **alucinan productos**: inventan SKUs, precios y disponibilidad que no existen en el catálogo real. El cliente termina recibiendo una recomendación falsa, abre la URL del producto, y el sitio devuelve 404. Daño de marca + soporte saturado.

Este workflow resuelve eso interponiendo un post-procesador que **valida cada respuesta del LLM contra los datos reales** de la API antes de devolverla, y reescribe la respuesta si detecta inconsistencias por encima de un umbral.

## Arquitectura

```
Webhook → Validate & Classify → Store API → Pre-filter & Rank → Switch (provider)
                                                                       ↓
                                                       OpenAI ──┬── Anthropic
                                                                ↓
                                                         Normalize LLM
                                                                ↓
                                                       Anti-hallucination
                                                                ↓
                                                       Telemetry (PG)
                                                                ↓
                                                       Format → Respond
```

Diagrama detallado en [`docs/architecture.md`](./docs/architecture.md).

## Stack

- **n8n** (self-hosted, v1.x) — orquestación
- **WooCommerce Store API** (`/wp-json/wc/store/products`) — público, no requiere auth (para `/wc/v3` admin sí, pero acá no hace falta)
- **LLM**: OpenAI GPT-4o-mini *o* Anthropic Claude Sonnet 4.5 (intercambiables vía env)
- **Postgres** — telemetría (schema en `sql/001_telemetry_schema.sql`)
- **i18n**: respuestas en `en` o `es` controladas por `BOT_LANG` env var

## Decisiones técnicas destacadas

### Post-procesador anti-hallucination (4 sub-componentes)

Es el corazón del workflow. Su única responsabilidad: **garantizar que ningún producto inventado por el LLM llegue al cliente**. El nodo `Anti-hallucination` ejecuta cuatro checks secuenciales sobre la respuesta del LLM:

#### 1. Real-ID extractor

El system prompt fuerza al LLM a devolver JSON con `mentioned_ids: [<números>]`. El extractor parsea ese array como conjunto de IDs candidatos.

```js
const mentioned = (llm.mentioned_ids || []).map(String);
```

Aplicar `String()` evita que un `5` y un `"5"` se traten como distintos al cross-checkear.

#### 2. Cross-check vs IDs reales

Comparamos `mentioned` contra el `Set` de IDs que devolvió la WooCommerce Store API en este request:

```js
const realIds = new Set(real.map(p => String(p.id)));
const valid_ids   = mentioned.filter(id =>  realIds.has(id));
const invalid_ids = mentioned.filter(id => !realIds.has(id));
```

Cualquier ID en `invalid_ids` es un producto inventado por el LLM.

#### 3. Stock & price verifier

No basta con que el ID exista — el LLM puede mencionar un ID válido pero **describirlo incorrectamente**. Dos checks:

- **Stock**: si el LLM dice "está disponible" pero la API marcó `is_in_stock: false`, se suma a `stock_inconsistencies`.
- **Precio**: extraemos números monetarios del texto del LLM (`$\d+`) y los comparamos contra el `prices.price` real. Si el más cercano difiere en más del 5%, se suma a `price_inconsistencies`.

```js
const closeMatch = priceMatches.find(n => Math.abs(n - realPrice) / realPrice < 0.05);
if (!closeMatch) price_inconsistencies.push({ id, name, real_price, mentioned_prices });
```

#### 4. Hallucination scoring + sanitization

Combinamos los tres tipos de issue en un score 0..1:

```js
const total_issues = invalid_ids.length + stock_inconsistencies.length + price_inconsistencies.length;
const hallucination_score = total_mentioned === 0
  ? (total_issues > 0 ? 1 : 0)
  : Math.min(1, total_issues / Math.max(1, total_mentioned));
```

Si `score >= 0.3` (configurable como `HALLUCINATION_THRESHOLD`) o hay cualquier `invalid_id`, **se descarta la respuesta del LLM y se reconstruye una desde la API**, usando un helper de i18n controlado por `BOT_LANG`:

```js
const lang = ($env.BOT_LANG || 'en').toLowerCase().startsWith('es') ? 'es' : 'en';
const T = {
  en: { found_n: (n) => `Found ${n} product${n === 1 ? '' : 's'} that might interest you:`, ... },
  es: { found_n: (n) => `Encontré ${n} producto${n === 1 ? '' : 's'} que podrian interesarte:`, ... }
}[lang];

const top = real.slice(0, data.max_results);
const lines = top.map((p, i) => `${i + 1}. **${p.name}** — ${p.currency} ${p.price}`).join('\n');
final_reply = `${T.found_n(real.length)}\n\n${lines}`;
```

El cliente nunca ve la salida sucia. Y el evento queda registrado en `bot_telemetry` con `sanitized=true` y la razón (`hallucination_threshold_exceeded` | `no_results` | `llm_parse_error`).

### Materialización de proxies en Code nodes

Los Code nodes que cruzan datos entre nodos previos (`$('Otro Nodo').item.json`) **deben materializar los proxies** antes de operar:

```js
const ctx = JSON.parse(JSON.stringify($('Validate & Classify').item.json));
const raw = JSON.parse(JSON.stringify($input.item.json));
```

Sin eso, n8n usa proxies lazy que cuando los datos tienen objetos profundamente anidados (productos WC traen `prices`, `images`, `attributes`) **disparan timeout del Task Runner**. La materialización fuerza serialización a primitivos.

### Switch v3 con `conditions.options` completos

```json
"conditions": {
  "options": { "caseSensitive": true, "leftValue": "", "typeValidation": "strict", "version": 2 },
  "combinator": "and",
  "conditions": [...]
}
```

Si faltan campos del objeto `options` (`caseSensitive`, `leftValue`, `typeValidation`, `version`), n8n v1.x tira *"Cannot read properties of undefined (reading 'caseSensitive')"* en runtime — aunque el nodo aparezca configurado en la UI.

### `per_page = max_results * 3`

La Store API se llama con triple del cupo final. Después del pre-filter (out-of-stock + filtros de precio), suele quedar la cantidad pedida sin tener que paginar. Reduce 60% de los casos donde tendríamos que ir a una segunda página.

### Telemetría con `continueOnFail`

El nodo Postgres tiene `continueOnFail: true`. Si la base se cae o el INSERT falla, el cliente igual recibe la respuesta — la observabilidad nunca debería bloquear el camino crítico.

## Setup

### 1. Variables de entorno

Copiar `.env.example` a `.env.local` y completar:

```bash
cp .env.example .env.local
```

Variables relevantes:

| Var | Default | Descripción |
|---|---|---|
| `STORE_BASE_URL` | (demo ficticia) | Base URL de tu WooCommerce, sin trailing slash |
| `LLM_PROVIDER` | `openai` | `openai` \| `anthropic` |
| `OPENAI_API_KEY` | — | requerido si `LLM_PROVIDER=openai` |
| `ANTHROPIC_API_KEY` | — | requerido si `LLM_PROVIDER=anthropic` |
| `BOT_LANG` | `en` | `en` \| `es` — idioma de respuestas |

Cargá las variables en n8n: en self-hosted las exponés al runtime con `docker-compose.yml` (`environment:`) o vía `~/.n8n/.env` según tu setup.

### 2. Base de datos de telemetría

```bash
psql $DATABASE_URL -f sql/001_telemetry_schema.sql
```

Crea la tabla `bot_telemetry` y la vista `bot_telemetry_health` (rollup horario por provider, últimos 7 días).

### 3. Credencial Postgres en n8n

En n8n: **Settings → Credentials → New → Postgres**. Nombre exacto: `bot_telemetry_db`. El workflow referencia ese nombre.

> ⚠️ Después de importar el JSON, abrí el nodo "Telemetry: Postgres" y reasignale la credencial — el ID interno (`REPLACE_WITH_YOUR_PG_CREDENTIAL_ID`) es un placeholder.

### 4. Importar workflow

n8n UI → **Workflows → Import from File** → seleccionar `workflow.json`.

### 5. Activar y testear

Activá el workflow. El webhook queda en `https://tu-n8n.example.com/webhook/acme-search`.

```bash
curl -X POST https://tu-n8n.example.com/webhook/acme-search \
  -H "Content-Type: application/json" \
  -d '{"query": "laptop gamer", "max_results": 4}'
```

## Examples

3 ejemplos completos con request + response esperado en [`docs/curl-examples.md`](./docs/curl-examples.md).
Postman collection lista para importar en [`docs/postman-collection.json`](./docs/postman-collection.json).

Resumen:

| # | Query                          | Demuestra                                                             |
|---|--------------------------------|-----------------------------------------------------------------------|
| 1 | `laptop gamer`                 | Flow nominal — clasificación por keywords + LLM válido                |
| 2 | `monitor 4k menos de 500`      | Parser de price hints en lenguaje natural                             |
| 3 | `auriculares bluetooth premium`| Hallucination → sanitization (validation.sanitized=true en response)  |

## Switching LLM providers

El switch entre OpenAI y Anthropic es 1 variable:

```bash
# .env.local
LLM_PROVIDER=openai     # default
# LLM_PROVIDER=anthropic
```

El nodo `Switch: LLM Provider` lee `$env.LLM_PROVIDER` y rutea al HTTP request correspondiente. **No hace falta tocar el JSON ni reimportar.**

### Cambiar modelo dentro de un provider

| Provider | Default | Características |
|---|---|---|
| **OpenAI** | `gpt-4o-mini` | Sweet spot calidad/costo. Para mayor calidad: `gpt-4o`. |
| **Anthropic** | `claude-sonnet-4-5` | Sweet spot productivo (recomendado). Para baja latencia / costo bajo: `claude-haiku-4-5-20251001`. Para máxima calidad: `claude-opus-4-7`. |

Para cambiar: abrir el nodo correspondiente en el canvas y editar el campo `"model"` del body JSON.

### Agregar un tercer provider (ej. Mistral, Cohere)

1. Duplicar uno de los nodos HTTP (OpenAI / Anthropic).
2. Cambiar URL y headers.
3. Agregar una rama nueva en el `Switch: LLM Provider` con el nuevo `outputKey`.
4. Conectar la salida nueva a `Normalize LLM` y agregar el branch de parsing en ese Code node:

```js
} else if (provider === 'mistral') {
  content = raw.choices && raw.choices[0] ? raw.choices[0].message.content : '';
}
```

## Switching response language

El bot responde en inglés por defecto. Para cambiarlo:

```bash
# .env.local
BOT_LANG=es     # respuestas en español rioplatense (voseo)
# BOT_LANG=en   # default — inglés
```

`BOT_LANG` afecta dos lugares:

1. **System prompt del LLM** — los nodos OpenAI y Anthropic lo leen vía expression para inyectar `Respond in English.` o `Respond in Spanish (rioplatense, voseo).` al final del system prompt.
2. **Strings de fallback del post-procesador** — cuando se dispara sanitization, los mensajes que reemplazan la respuesta del LLM ("Found N products...", "No products found...") se generan desde un objeto `T` con tabla de strings por idioma dentro del Code node `Anti-hallucination`.

Para agregar un idioma nuevo, editar el `T` en `Anti-hallucination` y la expresión ternaria del system prompt en los dos nodos LLM. Ejemplo en `Anti-hallucination`:

```js
const T = {
  en: {...},
  es: {...},
  pt: {  // nuevo
    no_results: (q) => `Nenhum produto encontrado para "${q}".`,
    found_n:    (n) => `Encontrei ${n} produto${n === 1 ? '' : 's'}:`,
    out_of_stock: 'consultar disponibilidade'
  }
}[lang];
```

## Estructura de archivos

```
e-commerce-product-search-bot/
├── README.md
├── workflow.json                  # 16 nodos (12 funcionales + 4 sticky notes), importable a n8n
├── .env.example
├── sql/
│   └── 001_telemetry_schema.sql   # tabla bot_telemetry + vista health
└── docs/
    ├── architecture.md            # diagrama detallado + tabla de datos por nodo
    ├── curl-examples.md           # 3 requests con response esperado
    └── postman-collection.json    # collection importable a Postman
```

---

[← Volver al índice](../../README.md)
