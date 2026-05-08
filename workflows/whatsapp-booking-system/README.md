# 💬 WhatsApp Booking System

> Sistema de reservas conversacional via WhatsApp con n8n + Evolution API + Google Calendar + Postgres. State machine persistido, idempotencia de webhooks, two-phase commit lite contra race conditions, y manejo correcto de timezones.

## Problema

Un negocio que recibe reservas por WhatsApp tiene tres dolores recurrentes:

1. **Estado conversacional**: el usuario manda "quiero un turno", "para el martes", "a las 11" en mensajes separados — y el bot tiene que recordar el contexto.
2. **Race conditions**: dos personas piden el mismo horario al mismo tiempo. ¿Quién gana?
3. **Idempotencia**: Evolution API reenvía webhooks ante timeouts, y sin protección el sistema crea dos reservas o manda dos respuestas.

Plus: las fechas tienen que entenderse en zona horaria local pero guardarse en UTC, sin perder coherencia entre Postgres, Google Calendar y el texto al usuario.

Este workflow resuelve los cuatro casos en un solo flujo, con código n8n + SQL atómico.

## Arquitectura

```
WA → Evolution → [Idempotency] → [State Load] → [GCal Busy] → [LLM (state-aware)] → [Action Switch]
                                                                                        ↓
                                                                  [Insert Pending] → [GCal Create] → [Mark Confirmed]
                                                                                        ↓
                                                                  [Compose] → [Update Session] → [Send WA] → [Respond]
```

Diagrama detallado en [`docs/architecture.md`](./docs/architecture.md).

## Stack

- **n8n** (self-hosted, v1.x) — orquestación
- **Evolution API** — gateway WhatsApp Business (inbound webhook + outbound sendText)
- **Postgres** — sessions + bookings + idempotency keys (schema en `sql/001_booking_schema.sql`)
- **Google Calendar API** — disponibilidad (GET busy) + creación de eventos (POST events)
- **LLM**: OpenAI `gpt-4o-mini` o Anthropic `claude-sonnet-4-5` (intercambiables vía env)
- **i18n**: respuestas en `en` o `es` controladas por `BOT_LANG`
- **Timezones**: storage UTC, display via `BUSINESS_TIMEZONE`

## Decisiones técnicas destacadas

### 1. Estado conversacional persistido en Postgres

Un workflow n8n es **stateless por ejecución**: cada mensaje WhatsApp dispara una nueva run que arranca limpia. Para mantener una conversación coherente entre mensajes, el estado vive en una tabla.

**Schema** (`booking_sessions`):

```sql
CREATE TABLE booking_sessions (
    session_key     TEXT PRIMARY KEY,                  -- "{business_id}:{phone}"
    business_id     UUID NOT NULL,
    phone           TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'IDLE',      -- IDLE | BOOKING_SERVICE | BOOKING_DATE | BOOKING_TIME | BOOKING_CONFIRM | BOOKED
    context         JSONB NOT NULL DEFAULT '{}'::JSONB,
    last_message_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '30 minutes'
);
```

**Por qué Postgres y no in-memory / Redis:**

- n8n se reinicia con frecuencia (deploys, scaling, OOMs). RAM es volátil.
- Postgres ya está en el stack para `bookings` — no agregamos infraestructura.
- `JSONB` en `context` permite agregar campos al state machine sin migración (slot tentativo, reserva en revisión, etc.).
- Sobrevive a postmortems: podemos analizar conversaciones reales para entrenar al LLM.

**Cómo se transita:** el `Compose Response` Code node decide `next_state` desde un mapping `next_action → state`. El UPSERT al final de cada turn extiende el TTL 30 min.

### 2. Race conditions: two-phase commit lite

El escenario: dos clientes piden a las 11:00 hs del martes el mismo servicio, **al mismo segundo**. ¿Cómo evitamos que ambos reciban "confirmado" cuando solo hay un slot?

**Pattern usado: `INSERT … ON CONFLICT DO NOTHING RETURNING` con UNIQUE parcial.**

```sql
CREATE UNIQUE INDEX uniq_active_booking
    ON bookings (service_id, start_at)
    WHERE status IN ('PENDING', 'CONFIRMED');
```

El INSERT del primer paso del booking actúa como **lock optimista atómico**:

```sql
INSERT INTO bookings (..., status='PENDING')
VALUES (...)
ON CONFLICT (service_id, start_at) WHERE status IN ('PENDING','CONFIRMED')
DO NOTHING
RETURNING id, start_at, end_at;
```

Si dos requests pegan en el mismo nanosegundo, **Postgres serializa el INSERT a nivel de índice**. Uno gana (recibe la fila), el otro recibe `[]` y el workflow cae a la rama "ese horario lo acaba de tomar otra persona".

Después del INSERT exitoso:

1. POST a Google Calendar para crear el evento.
2. UPDATE bookings SET status='CONFIRMED', google_event_id=...

**Two-phase porque:**

- **Phase 1** = INSERT PENDING (lock)
- **Phase 2** = Calendar create + UPDATE CONFIRMED (commit)

Si Phase 2 falla (Calendar caído), el row queda en `PENDING`. Un sweeper cron lo expira:

```sql
UPDATE bookings SET status='EXPIRED'
WHERE status='PENDING' AND created_at < NOW() - INTERVAL '60 seconds';
```

El UNIQUE parcial deja libre el slot al pasar a `EXPIRED` (ya no matchea el WHERE), por lo que un próximo cliente puede tomarlo.

**Por qué no advisory locks:** `pg_advisory_xact_lock` solo dura mientras la transacción está abierta. Cada query desde n8n abre una conexión nueva — el lock se libera entre nodos. La pattern del UNIQUE constraint es atómica en una sola query y no necesita coordinación entre nodos.

### 3. Idempotencia — dedup de webhooks

Evolution API reintenta webhooks ante timeouts (defecto: 3 reintentos con backoff). Sin dedup, el mismo mensaje crea dos reservas.

**Pattern:** primer nodo después del Webhook es

```sql
INSERT INTO message_idempotency (message_id, business_id)
VALUES ($1, $2)
ON CONFLICT (message_id) DO NOTHING
RETURNING message_id;
```

El nodo `IF: New Message?` evalúa si `message_id` está vacío en el output:

- **Vacío** = el `INSERT` no devolvió fila = mensaje ya procesado → ruta a `Respond 200 (duplicate)` y termina.
- **No vacío** = primer procesamiento → continúa con el flujo normal.

El short-circuit ocurre **antes** de cualquier llamada a LLM, Calendar o Postgres pesado. Si Evolution mete 50 reintentos por error, los 49 extras cuestan 1 INSERT cada uno.

**TTL:** 24h. Un cron diario hace `DELETE FROM message_idempotency WHERE processed_at < NOW() - INTERVAL '24 hours'`.

### 4. Timezones — UTC en el core, local en los bordes

Tres lugares manejan fechas:

| Lugar             | Formato                                 | Por qué                                  |
|-------------------|-----------------------------------------|------------------------------------------|
| Postgres          | `TIMESTAMPTZ` UTC siempre               | Comparaciones consistentes, sin DST drift|
| LLM context       | `current_time_local` (string en TZ negocio) | El LLM razona "mañana a las 11" desde la TZ correcta |
| Google Calendar   | `dateTime` ISO + `timeZone` field       | El calendario muestra la hora local; el storage de Google es UTC |
| Reply al usuario  | `Intl.DateTimeFormat({ timeZone })`     | El usuario ve "martes 13 de mayo a las 11:00", no UTC |

**Cómo se inyecta la TZ al LLM** (Code node `Build LLM Context`):

```js
const tz = $env.BUSINESS_TIMEZONE || 'America/Argentina/Buenos_Aires';
const nowInTz = new Intl.DateTimeFormat('en-CA', {
  timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', hour12: false
}).format(new Date());
// => "2026-05-08, 14:32"
```

Eso se le pasa al system prompt como "Now (America/Argentina/Buenos_Aires): 2026-05-08, 14:32". El LLM resuelve "mañana a las 11" → ISO 8601 con offset correcto.

**Validación adicional** en `Normalize & Validate LLM`:

```js
const t = Date.parse(extracted.start_at);
if (!isNaN(t) && t > Date.now()) start_at_iso = new Date(t).toISOString();
```

Rechaza fechas en el pasado o no parseables. Sin esto el LLM podría decir "te reservé para 2024-03-04" y crearíamos una reserva imposible.

## Setup

### 1. Variables de entorno

Copiar `.env.example` a `.env.local` y completar:

```bash
cp .env.example .env.local
```

| Var | Descripción |
|---|---|
| `BUSINESS_ID` | UUID v4 del comercio (matchea seed del SQL) |
| `BUSINESS_TIMEZONE` | IANA TZ (ej. `America/Argentina/Buenos_Aires`) |
| `EVOLUTION_API_URL`, `EVOLUTION_API_KEY`, `EVOLUTION_INSTANCE` | Tu instancia Evolution API |
| `LLM_PROVIDER` | `openai` \| `anthropic` |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | según provider |
| `BOT_LANG` | `en` (default) \| `es` |
| `GOOGLE_CALENDAR_ID` | `primary` o un calendar ID dedicado |

### 2. Base de datos

```bash
psql $DATABASE_URL -f sql/001_booking_schema.sql
```

Crea las 4 tablas (`services`, `bookings`, `booking_sessions`, `message_idempotency`) + el UNIQUE parcial + seed con 4 servicios para ACME Studio.

### 3. Credenciales en n8n

| Credencial n8n | Tipo | Nombre exacto |
|---|---|---|
| Postgres | `postgres` | `booking_db` |
| Google Calendar OAuth2 | `googleCalendarOAuth2Api` | `google_calendar_oauth` |

> ⚠️ Después de importar el `workflow.json`, abrí los 4 nodos Postgres y los 2 nodos Google Calendar y reasigná las credenciales — los IDs internos (`REPLACE_WITH_*`) son placeholders.

### 4. Sweepers (cron)

Agregar a tu scheduler (cron de Linux, n8n Schedule node, etc.):

```sql
-- cada minuto
UPDATE bookings SET status='EXPIRED'
WHERE status='PENDING' AND created_at < NOW() - INTERVAL '60 seconds';

-- cada hora
DELETE FROM booking_sessions WHERE expires_at < NOW() - INTERVAL '1 hour';

-- nightly
DELETE FROM message_idempotency WHERE processed_at < NOW() - INTERVAL '24 hours';
```

### 5. Importar y activar

n8n UI → **Workflows → Import from File** → seleccionar `workflow.json` → reasignar credenciales → Activar.

El webhook queda en `https://tu-n8n.example.com/webhook/acme-studio-wa`. Configurá Evolution API para apuntar `messages.upsert` ahí.

## Examples

4 ejemplos completos (greeting → service → confirm → idempotency replay) en [`docs/curl-examples.md`](./docs/curl-examples.md).
Postman collection con tests automatizados en [`docs/postman-collection.json`](./docs/postman-collection.json).

| # | Mensaje                                  | Demuestra                                                             |
|---|------------------------------------------|-----------------------------------------------------------------------|
| 1 | `Hola, querría reservar un turno`        | Inicio: idempotency + session UPSERT + greeting                       |
| 2 | `Corte clásico, mañana a las 11am`       | Slot filling: el LLM extrae servicio + start_at en una sola turn      |
| 3 | `Sí, confirmo`                           | Two-phase commit: INSERT PENDING → Calendar → UPDATE CONFIRMED        |
| 4 | (replay del mensaje 1 con mismo `id`)    | Idempotency short-circuit: 200 silently, sin side-effects             |

## Switching LLM providers

Igual que el resto de los workflows del showcase: 1 env var.

```bash
LLM_PROVIDER=openai     # default
# LLM_PROVIDER=anthropic
```

| Provider | Default | Características |
|---|---|---|
| **OpenAI** | `gpt-4o-mini` | Sweet spot calidad/costo. Para mayor calidad: `gpt-4o`. |
| **Anthropic** | `claude-sonnet-4-5` | Sweet spot productivo. Para baja latencia: `claude-haiku-4-5-20251001`. Para máxima calidad: `claude-opus-4-7`. |

## Switching response language

```bash
BOT_LANG=es     # respuestas en español rioplatense
# BOT_LANG=en   # default
```

`BOT_LANG` afecta:

1. **System prompt del LLM** — agrega `Respond in English.` o `Respond in Spanish (rioplatense, voseo).` al final.
2. **Strings de fallback en `Compose Response`** — tabla `T = { en: {...}, es: {...} }` para mensajes de "Listo!", "ese slot lo tomaron", "no entendí".
3. **Formato de fecha** — `Intl.DateTimeFormat('es-AR' | 'en-US')` cambia el orden y el case ("Tuesday, May 13" vs "martes, 13 de mayo").

## Extender — cancelar y reprogramar

El workflow base implementa `book` y `consult`. Agregar `cancel` / `reschedule` requiere:

1. **Whitelist** los nuevos `next_action` values en `Normalize & Validate LLM` (`process_cancel`, `process_reschedule`).
2. **Agregar branches** al `Switch: Action`:
   - `process_cancel` → `SELECT bookings WHERE customer_phone=$1 AND status='CONFIRMED'` → `DELETE` Calendar event → `UPDATE status='CANCELLED', cancelled_at=NOW()`.
   - `process_reschedule` → ejecutar cancel + lanzar el flujo de book con la nueva fecha.
3. **Extender `STATE_BY_ACTION`** en `Compose Response`.

El patrón es el mismo: el LLM determina el siguiente paso, el workflow valida y ejecuta atómicamente contra la DB.

## Estructura de archivos

```
whatsapp-booking-system/
├── README.md
├── workflow.json                  # 25 nodos (20 funcionales + 5 sticky notes), importable a n8n
├── .env.example
├── sql/
│   └── 001_booking_schema.sql     # 4 tablas + UNIQUE parcial + seed
└── docs/
    ├── architecture.md            # diagrama detallado + state machine + tabla de fallos
    ├── curl-examples.md           # 4 requests con response esperado
    └── postman-collection.json    # collection con env vars + 12 tests automatizados
```

---

[← Volver al índice](../../README.md)
