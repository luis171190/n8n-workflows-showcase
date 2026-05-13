# 📞 Voice AI Lead Qualifier — Retell AI + n8n

> Calificacion automatica de leads via llamadas salientes con voz IA. Un nuevo lead llega por webhook, el sistema decide si llamar en ese momento (cumplimiento horario, DNC check), lanza la llamada via Retell AI, y cuando termina analiza la transcripcion con un LLM para extraer score BANT y rutear: agendar reunion, nurturing o descalificar.

## Problema

Un equipo de ventas recibe leads de landing pages, webinars y formularios. La calificacion manual tiene tres problemas:

- **Velocidad**: el lead tarda horas en recibir una llamada. La ventana de conversion cae 80% en 5 minutos.
- **Consistencia**: cada SDR califica diferente, sin framework estructurado.
- **Escala**: un humano puede hacer 30-40 llamadas/dia; el sistema hace cientos sin costo fijo marginal.

La calificacion con voz IA resuelve los tres. Pero una implementacion naive rompe en produccion:

1. El mismo lead llega dos veces → dos llamadas al mismo contacto. → **Idempotencia en inbound**.
2. Se llama a alguien que pidio no ser contactado. → **DNC check antes de cualquier call**.
3. Se llama a las 2am del destinatario. → **Compliance horario TZ-aware**.
4. Retell hace retry del post-call webhook → el lead queda marcado dos veces, doble calendario. → **Idempotencia en post-call**.
5. El LLM devuelve JSON malformado → crash en produccion. → **Safe defaults en extraccion BANT**.
6. El lead llega fuera de horario → se pierde. → **Cola con drainer + backoff exponencial**.
7. No hay visibilidad de costos. → **Registro granular en `call_costs`**.

Este workflow resuelve los 7.

## Arquitectura

```
SUBFLOW A — Lead Inbound
  Webhook: New Lead (/webhook/new-lead)
      │
  Validate + Enrich     ← email format, phone E.164, domain lookup
      │
  Idempotency: Lead     ← INSERT leads ON CONFLICT (email) DO NOTHING
      │
  Lead: New? ─── NO ──► Respond 200 (already_queued)
      │
      YES
      │
  DNC Check             ← SELECT FROM dnc_list WHERE phone
      │
  Lead: On DNC? ── YES ─► Mark DNC → Respond 200 (blocked)
      │
      NO
      │
  Compliance: Working Hours  ← TZ-aware, calculates next-slot
      │
  Lead: In Hours? ── NO ──► Queue: Out of Hours → Respond 202
      │
      YES
      │
  Trigger Retell Call   ← POST /v2/create-phone-call (continueOnFail)
      │
  Persist Call Attempt  ← INSERT call_attempts
      │
  Respond 200 (call_initiated)

SUBFLOW B — Post-Call Analysis (Retell callback)
  Webhook: Retell Post-Call (/webhook/retell-post-call)
      │
  Idempotency: Call     ← INSERT processed_calls ON CONFLICT
      │
  Parse Retell Payload  ← transcript, duration, cost, lead_id
      │
  Switch: LLM Provider  ← $env.LLM_PROVIDER
      │             │
  OpenAI: Analyze  Anthropic: Analyze  ← structured JSON schema
      │             │
  Normalize + BANT Extract  ← whitelist, safe defaults, reconcile intent
      │
  Update Lead + Insert Cost  ← CTE: UPDATE leads + INSERT call_costs
      │
  Route by Intent
      │          │          │
     hot        warm       cold
      │          │          │
  GCal+Airtable nurture_queue Respond 200 (disqualified)

SUBFLOW C — Queue Drainer (cron every 5 min)
  Fetch WAITING queue items → Trigger Retell → Update status
  (exponential backoff: POWER(2, retry_count) * 15 min, GAVE_UP at 10)
```

Diagrama detallado, datos por nodo y failure modes en [`docs/architecture.md`](./docs/architecture.md).

## Stack

- **n8n** (self-hosted, v1.x)
- **Retell AI** — outbound voice agent + post-call webhooks
- **OpenAI** (`gpt-4o-mini`) / **Anthropic** (`claude-sonnet-4-5`) — transcript analysis, switchable via `LLM_PROVIDER`
- **Google Calendar API** — meeting scheduling for hot leads
- **Airtable REST API** — CRM deal creation for hot leads
- **Postgres** — leads, call_attempts, processed_calls, call_queue, call_costs, dnc_list, nurture_queue (schema en `sql/001_lead_qualifier_schema.sql`)

## Decisiones tecnicas destacadas

### 1. Async voice flow — no polling

La llamada NO es sincronica. n8n dispara Retell y responde 200 de inmediato:

```
Subflow A: POST /v2/create-phone-call → 200 (call_initiated)
                                          [conversacion 2-5 min]
Subflow B:                    ← POST /webhook/retell-post-call
```

Esto mantiene el webhook de inbound en < 500ms y desacopla completamente la ingesta del analisis. Si Retell tarda en devolver el callback, Subflow A ya respondio hace minutos.

### 2. BANT con structured output

El LLM recibe la transcripcion y produce JSON forzado por schema:

```json
{
  "bant": {
    "budget":    "confirmed | unconfirmed | no_budget",
    "authority": "decision_maker | influencer | unknown",
    "need":      "strong | moderate | weak",
    "timing":    "immediate | 1_3_months | 3_6_months | unknown"
  },
  "score":      0,
  "intent":     "hot | warm | cold | disqualified",
  "objections": [],
  "summary":    "One-sentence call summary",
  "next_action":"schedule_meeting | nurture | disqualify"
}
```

**Por que structured output**: en produccion, parsear texto libre es fragil. Con JSON schema activado (OpenAI response_format / Anthropic tool_use), el LLM no puede devolver texto fuera del schema. La razon del `Normalize + BANT Extract` adicional es sanitizar los valores (whitelist de enums) y aplicar defaults seguros si igual hay un parse error.

El nodo `Normalize + BANT Extract` reconcilia:

```javascript
if (result.intent === 'hot' && result.next_action !== 'schedule_meeting')
    result.next_action = 'schedule_meeting';
if (result.intent === 'cold' || result.intent === 'disqualified')
    result.next_action = 'disqualify';
```

Esto evita que un LLM indeciso devuelva `intent='hot'` con `next_action='nurture'`.

### 3. System prompt de Retell (recomendado)

```
Sos un SDR de [Empresa]. Tu objetivo es calificar leads en 3-5 minutos.
Cubrí los 4 puntos BANT en orden natural, sin sonar a interrogatorio:
1. Necesidad: "Que problema concreto estan tratando de resolver?"
2. Presupuesto: "Tienen presupuesto aprobado para este tipo de solucion?"
3. Autoridad: "Vos sos quien toma la decision final o hay otros involucrados?"
4. Timing: "Para cuando necesitarian tener esto en marcha?"

Siempre:
- Usas el nombre del prospecto.
- Si no estan interesados, agradeces y terminas amablemente.
- NUNCA prometes precios ni fechas especificas.
- Si piden salir de la lista: confirmá que los removés y terminá la llamada.
```

Configurar este prompt en el panel de Retell bajo "Agent Settings > System Prompt".

### 4. Deduplicacion de dos capas

| Evento | Tabla | Mecanismo |
|---|---|---|
| Nuevo lead | `leads` | UNIQUE `email` → `INSERT ON CONFLICT DO NOTHING RETURNING id` |
| Post-call webhook | `processed_calls` | PRIMARY KEY `retell_call_id` → `INSERT ON CONFLICT DO NOTHING` |

Dos layers distintos porque el duplicate puede venir de:
- **Lead**: el mismo formulario submitteado dos veces, o dos sources distintas capturando el mismo contacto.
- **Post-call**: Retell reintenta el webhook si no recibe 200 en 5 segundos.

### 5. Compliance horario TZ-aware

```javascript
const tz = $env.BUSINESS_TIMEZONE || 'America/New_York';
const hStart = parseInt($env.WORKING_HOURS_START || '9');
const hEnd   = parseInt($env.WORKING_HOURS_END   || '18');
const now    = new Date();
const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hour: 'numeric', hour12: false,
    weekday: 'short'
});
const parts = formatter.formatToParts(now);
const hourLocal   = parseInt(parts.find(p => p.type === 'hour').value);
const weekdayShort = parts.find(p => p.type === 'weekday').value;
const isWeekend = ['Sat','Sun'].includes(weekdayShort);
const in_hours  = !isWeekend && hourLocal >= hStart && hourLocal < hEnd;
```

Si `in_hours === false`, el nodo calcula el proximo slot valido (siguiente dia laboral a las `hStart`) y lo inserta en `call_queue`. El drainer lo recupera cuando `scheduled_at <= NOW()`.

### 6. Rate limiting y backoff exponencial

El drainer aplica backoff en los reintentos fallidos:

```sql
UPDATE call_queue SET
    retry_count  = retry_count + 1,
    last_error   = $error,
    scheduled_at = NOW() + (POWER(2, retry_count) * INTERVAL '15 minutes'),
    status       = CASE WHEN retry_count + 1 >= 10 THEN 'GAVE_UP' ELSE 'WAITING' END
WHERE id = $queue_id;
```

| retry_count | Proximo intento |
|---|---|
| 0 | +15 min |
| 1 | +30 min |
| 2 | +60 min |
| 3 | +2h |
| 4 | +4h |
| 5 | +8h |
| >= 10 | GAVE_UP |

### 7. Registro de costos por llamada

Cada callback de Retell incluye el costo de la llamada. El nodo `Normalize + BANT Extract` calcula el costo de analisis LLM por tokens:

```javascript
const COST_PER_1K_TOKENS = provider === 'openai' ? 0.00015 : 0.0008;
const totalTokens = (rawOutput.usage?.total_tokens || 0);
const analysis_cost_usd = (totalTokens / 1000) * COST_PER_1K_TOKENS;
```

El nodo `Update Lead + Insert Cost` persiste ambos en un CTE atomico:

```sql
WITH cost_insert AS (
    INSERT INTO call_costs (call_attempt_id, lead_id, provider, duration_sec, cost_usd, model_used, analysis_cost_usd)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
)
UPDATE leads SET
    bant_budget   = $budget, bant_authority = $authority,
    bant_need     = $need,   bant_timing    = $timing,
    bant_score    = $score,  intent         = $intent,
    next_action   = $next_action,
    call_summary  = $summary, objections    = $objections,
    status        = 'called', last_called_at = NOW(), updated_at = NOW()
WHERE id = $lead_id;
```

### 8. Safe defaults ante errores LLM

El nodo `Normalize + BANT Extract` nunca crashea en produccion:

```javascript
const SAFE = {
    bant: { budget:'unconfirmed', authority:'unknown', need:'weak', timing:'unknown' },
    score: 0, intent: 'warm', objections: [], 
    summary: 'Auto-fallback: LLM parse error',
    next_action: 'nurture'
};
let parsed = null;
try {
    parsed = JSON.parse(rawOutput);
    // whitelist validation ...
} catch (e) { /* use SAFE */ }
const result = parsed || SAFE;
```

El fallback tiene `intent='warm'` para que el lead vaya a nurturing en vez de descartarse silenciosamente. Se puede revisar manualmente consultando `call_summary ILIKE '%fallback%'`.

## Setup

### 1. Variables de entorno

Copiar `.env.example` a `.env.local` y completar.

| Var | Descripcion |
|---|---|
| `RETELL_API_KEY` | Desde el panel de Retell AI |
| `RETELL_AGENT_ID` | ID del agente configurado en Retell |
| `RETELL_FROM_NUMBER` | Numero E.164 provisionado en Retell |
| `LLM_PROVIDER` | `openai` o `anthropic` |
| `BUSINESS_TIMEZONE` | IANA tz del prospecto target (ej: `America/New_York`) |
| `WORKING_HOURS_START` / `WORKING_HOURS_END` | Rango horario local (ej: `9` y `18`) |
| `GOOGLE_CALENDAR_ID` | Para agendar reuniones de leads hot |
| `AIRTABLE_BASE_ID` / `AIRTABLE_API_KEY` | Para crear deals en Airtable |

### 2. Base de datos

```bash
psql $DATABASE_URL -f sql/001_lead_qualifier_schema.sql
```

Crea 7 tablas + triggers `updated_at` + seed DNC entry para testing.

### 3. Credenciales en n8n

| Credencial | Tipo | Nombre exacto |
|---|---|---|
| Postgres | `postgres` | `lead_qualifier_db` |
| Google Calendar | `googleCalendarOAuth2Api` | `google_calendar` |
| Airtable | `airtableTokenApi` | `airtable_crm` |

Los nodos Retell, OpenAI y Anthropic usan HTTP Request con `Authorization: Bearer {{$env.RETELL_API_KEY}}` etc. directamente en las expresiones.

### 4. Configurar Retell

1. En Retell Panel → Agents → New Agent. Configurar el system prompt (ver seccion de decisiones tecnicas).
2. En Retell Panel → Phone Numbers → importar o comprar numero. Asignarlo al agente.
3. En Retell Panel → Webhooks → agregar `https://tu-n8n.example.com/webhook/retell-post-call` como post-call webhook.

### 5. Importar y activar

n8n UI → Workflows → Import from File → seleccionar `workflow.json`. Reasignar credenciales. Activar los tres triggers.

## Examples

6 ejemplos completos en [`docs/curl-examples.md`](./docs/curl-examples.md). Postman collection con 6 requests y tests automatizados en [`docs/postman-collection.json`](./docs/postman-collection.json).

| # | Escenario | Demuestra |
|---|---|---|
| 1 | Nuevo lead (in-hours, not on DNC) | Happy path: validate → call initiated |
| 2 | Mismo lead repetido | Idempotencia inbound: `already_queued` |
| 3 | Lead en DNC | DNC filter: `blocked` |
| 4 | Post-call HOT (score 9) | BANT extraction + GCal + Airtable |
| 5 | Post-call WARM (score 5) | Nurture queue insertion |
| 6 | Replay post-call webhook | Idempotencia post-call: `already_processed` |

Ejemplo 4 (out-of-hours queue) esta en curl-examples.md pero no en Postman porque requiere cambiar la hora del sistema para activar el branch.

## Estructura de archivos

```
voice-ai-lead-qualifier/
├── README.md
├── workflow.json                        # 43 nodos (35 funcionales + 8 sticky notes), 3 triggers
├── .env.example
├── sql/
│   └── 001_lead_qualifier_schema.sql   # 7 tablas + triggers + seed DNC entry
└── docs/
    ├── architecture.md                  # flow diagrams + async voice flow + BANT decision tree + per-node table
    ├── curl-examples.md                 # 6 escenarios end-to-end
    └── postman-collection.json          # 6 requests + 12 tests automatizados
```

---

[← Volver al indice](../../README.md)
