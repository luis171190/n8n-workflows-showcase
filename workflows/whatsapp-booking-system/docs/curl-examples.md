# Curl examples — whatsapp-booking-system

> Replace `https://your-n8n.example.com` with your n8n instance.
> The workflow exposes path `/webhook/acme-studio-wa` (Evolution API webhook target).

The webhook expects the **Evolution API `messages.upsert` payload shape**. Below are simulated payloads you can use to drive the bot end-to-end without a real WhatsApp sender.

## 1. First message — greeting + intent detection

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/acme-studio-wa \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "key": {
        "remoteJid": "5491100000001@s.whatsapp.net",
        "fromMe": false,
        "id": "MSG_TEST_0001"
      },
      "pushName": "Test User",
      "message": {
        "conversation": "Hola, querría reservar un turno"
      }
    }
  }'
```

**Response (HTTP 200):**

```json
{
  "status": "ok",
  "session_key": "00000000-0000-0000-0000-000000000001:5491100000001",
  "next_state": "BOOKING_SERVICE",
  "reply": "¡Hola! Bienvenido a ACME Studio. ¿Qué servicio querrías reservar? Tenemos: corte clásico, corte + barba, color, y manicura.",
  "booking": null
}
```

The session row is created in `booking_sessions` with `state='BOOKING_SERVICE'`. The reply was also pushed back via Evolution API.

---

## 2. Same conversation — choose service

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/acme-studio-wa \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "key": {
        "remoteJid": "5491100000001@s.whatsapp.net",
        "fromMe": false,
        "id": "MSG_TEST_0002"
      },
      "pushName": "Test User",
      "message": { "conversation": "Corte clásico, mañana a las 11am" }
    }
  }'
```

**Response:**

```json
{
  "status": "ok",
  "session_key": "00000000-0000-0000-0000-000000000001:5491100000001",
  "next_state": "BOOKING_CONFIRM",
  "reply": "Perfecto. Te confirmo: corte clásico mañana a las 11:00. ¿Lo confirmás? (sí/no)",
  "booking": null
}
```

The LLM parsed `service_name="Corte clásico"` and `start_at` ISO from "mañana a las 11am" + business TZ. Stored in `context.tentative_start_at`.

---

## 3. User confirms — two-phase commit fires

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/acme-studio-wa \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "key": {
        "remoteJid": "5491100000001@s.whatsapp.net",
        "fromMe": false,
        "id": "MSG_TEST_0003"
      },
      "pushName": "Test User",
      "message": { "conversation": "Sí, confirmo" }
    }
  }'
```

**Response (happy path):**

```json
{
  "status": "ok",
  "session_key": "00000000-0000-0000-0000-000000000001:5491100000001",
  "next_state": "BOOKED",
  "reply": "¡Listo! Te reservé Classic haircut para mañana a las 11:00. Te esperamos. Respondé CANCELAR si querés cancelar.",
  "booking": {
    "id": "...uuid...",
    "status": "CONFIRMED",
    "start_at": "2026-05-09T14:00:00.000Z",
    "end_at":   "2026-05-09T14:30:00.000Z",
    "google_event_id": "..."
  }
}
```

**Response if slot was just taken by another user (race):**

```json
{
  "status": "ok",
  "next_state": "BOOKING_TIME",
  "reply": "Uy — ese horario lo acaba de tomar otra persona. Probamos con otro?",
  "booking": null
}
```

The session goes back to `BOOKING_TIME` so the user can pick another slot without restarting the flow.

---

## 4. Idempotency — same message_id replayed

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/acme-studio-wa \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "key": {
        "remoteJid": "5491100000001@s.whatsapp.net",
        "fromMe": false,
        "id": "MSG_TEST_0001"
      },
      "pushName": "Test User",
      "message": { "conversation": "Hola, querría reservar un turno" }
    }
  }'
```

**Response (HTTP 200):**

```json
{ "status": "already_processed" }
```

The `message_idempotency` table already has `MSG_TEST_0001`. The workflow short-circuits before any side effects (no second WhatsApp send, no second booking).

---

## Postman collection

Importable from [./postman-collection.json](./postman-collection.json) — includes the 4 scenarios with environment variables and schema-level automated tests.
