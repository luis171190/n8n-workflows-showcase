# Arquitectura — whatsapp-booking-system

## Diagrama de flujo

```
┌─────────────────────────────────┐
│  POST /webhook/acme-studio-wa   │  ← Evolution API webhook (mensaje WA entrante)
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Idempotency Insert             │  ← INSERT ON CONFLICT DO NOTHING RETURNING
│  (message_idempotency)          │     Si returns 0 rows → mensaje duplicado.
└────────────────┬────────────────┘
                 │
                 ▼
        ┌────────────────┐
        │ IF: New?       │
        └─┬────────────┬─┘
          │            │
       new│            │duplicate
          │            ▼
          │   ┌──────────────────────┐
          │   │ Respond 200          │  → END (silently 200, sin reenviar WA)
          │   └──────────────────────┘
          ▼
┌─────────────────────────────────┐
│  Parse Evolution Payload        │  ← Code: extrae phone, text, push_name, message_id.
│                                 │     Skip si fromMe=true (eco propio).
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Load/Init Session              │  ← UPSERT booking_sessions (key = business_id:phone).
│  (booking_sessions UPSERT)      │     Crea con state=IDLE si no existia.
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  GCal: Fetch Busy (14d)         │  ← GET /calendars/{id}/events para los proximos 14 dias.
│                                 │     Le damos al LLM la "agenda ocupada".
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Build LLM Context              │  ← Code: merge session.state + session.context +
│                                 │     services catalog + busy slots + tz local.
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Switch: LLM Provider           │  ← $env.LLM_PROVIDER routes openai | anthropic.
└──────┬───────────────┬──────────┘
       │               │
       ▼               ▼
┌──────────┐    ┌────────────┐
│  OpenAI  │    │  Anthropic │   ← Mismo system prompt en ambos. Devuelve JSON con
│          │    │  (Sonnet)  │      { intent, next_action, extracted, user_message }.
└──────┬───┘    └─────┬──────┘
       │              │
       └──────┬───────┘
              ▼
┌─────────────────────────────────┐
│  Normalize & Validate LLM       │  ← Whitelist intent + next_action + Date.parse(start_at) +
│                                 │     resolve service_id contra catalog. Defaults safe.
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Switch: Action                 │  ← Solo entra a "book" si TODO se cumple:
│                                 │     - next_action = confirm_booking
│                                 │     - user_confirmed = true
│                                 │     - service y start_at presentes
└──────┬─────────────────────┬────┘
       │                     │
       ▼ book                ▼ extra (default)
┌──────────────┐             │
│ Insert       │             │
│ Pending      │             │  ← INSERT bookings status=PENDING ON CONFLICT DO NOTHING
│ Booking      │             │     Si 0 rows → slot tomado por race.
└──────┬───────┘             │
       ▼                     │
┌──────────────┐             │
│ GCal: Create │             │  ← POST /calendars/{id}/events. continueOnFail=true.
│ Event        │             │     Si falla, el PENDING queda y el sweeper lo limpia.
└──────┬───────┘             │
       ▼                     │
┌──────────────┐             │
│ Mark Booking │             │  ← UPDATE bookings SET status='CONFIRMED', google_event_id=...
│ Confirmed    │             │
└──────┬───────┘             │
       │                     │
       └──────┬──────────────┘
              ▼
┌─────────────────────────────────┐
│  Compose Response               │  ← Code: i18n via BOT_LANG. Si vino booking → "Listo!".
│                                 │     Si Insert dio 0 rows → "ese slot lo tomaron".
│                                 │     Si no, usa el user_message del LLM.
│                                 │     Calcula next_state segun next_action.
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Update Session State           │  ← UPSERT booking_sessions con next_state + next_context.
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Send WhatsApp                  │  ← POST {EVOLUTION_API_URL}/message/sendText/{instance}
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Respond Webhook                │  → 200 { status, session_key, next_state, reply, booking }
└─────────────────────────────────┘
```

## State machine

```
                  ┌─────────┐
                  │  IDLE   │
                  └────┬────┘
                       │  message arrives
                       ▼
            ┌──────────────────────┐
            │ BOOKING_SERVICE      │   (LLM asked for service)
            └──────────┬───────────┘
                       │  service captured
                       ▼
            ┌──────────────────────┐
            │ BOOKING_DATE         │
            └──────────┬───────────┘
                       │  date captured
                       ▼
            ┌──────────────────────┐
            │ BOOKING_TIME         │   (also the recovery state if slot was just taken)
            └──────────┬───────────┘
                       │  time captured
                       ▼
            ┌──────────────────────┐
            │ BOOKING_CONFIRM      │
            └──────────┬───────────┘
                       │  user said yes & two-phase commit succeeded
                       ▼
                  ┌─────────┐
                  │ BOOKED  │   (terminal — context.booking_id set)
                  └─────────┘
```

The mapping `next_action -> next_state` lives in the `Compose Response` Code node, table `STATE_BY_ACTION`. Adding a new action means: (1) whitelist it in `Normalize & Validate LLM`, (2) add the row to the table, (3) optionally fork the `Switch: Action`.

## Datos que viajan entre nodos

| Nodo                          | Output principal                                                                          |
|-------------------------------|-------------------------------------------------------------------------------------------|
| Webhook                       | Raw Evolution payload (`body.data.{key,message,pushName}`)                                |
| Idempotency Insert            | `{message_id}` if new, empty if duplicate                                                 |
| Parse Evolution Payload       | `{message_id, phone, push_name, text, session_key, received_at}`                          |
| Load/Init Session             | `{session_key, state, context, expires_at}`                                               |
| GCal: Fetch Busy              | `{items: [{start, end, summary}]}` (raw Google response)                                  |
| Build LLM Context             | merged: session + busy + services + business_timezone + lang                              |
| Switch: LLM Provider          | (passthrough, branches)                                                                   |
| OpenAI / Anthropic            | provider raw response                                                                     |
| Normalize & Validate LLM      | + `{intent, next_action, extracted{service, start_at, user_confirmed}, user_message}`     |
| Switch: Action                | (passthrough, branches book / extra)                                                      |
| Insert Pending Booking        | `{id, start_at, end_at}` if won the race, empty if slot already taken                     |
| GCal: Create Event            | `{id, htmlLink, status, ...}` Google response                                             |
| Mark Booking Confirmed        | `{id, status, start_at, end_at, google_event_id}`                                         |
| Compose Response              | + `{reply_text, next_state, next_context, booking}`                                       |
| Update Session State          | `{session_key, state}`                                                                    |
| Send WhatsApp                 | Evolution response                                                                        |
| Respond Webhook               | `{status, session_key, next_state, reply, booking}`                                       |

## Fallos y compensaciones

| Falla                                      | Que pasa                                                          |
|--------------------------------------------|-------------------------------------------------------------------|
| Mensaje duplicado de Evolution             | Idempotency Insert returns 0 rows → IF rama dup → 200 silently    |
| Slot tomado por race                       | Insert Pending Booking returns 0 rows → Compose detecta `pending='taken'` y responde "intenta otro" |
| Google Calendar API caída                  | GCal: Create Event falla con `continueOnFail` → no se MARK CONFIRMED → sweeper expira el PENDING |
| LLM devuelve next_action invalido          | Normalize whitelist → cae a `fallback` → respuesta de ayuda       |
| Evolution API caída al enviar reply        | Send WhatsApp con `continueOnFail` → Respond Webhook igual cierra 200 (Evolution reintentara el inbound) |
| Postgres caído                             | Idempotency / Load Session fallan → workflow aborta → Evolution reintenta el inbound, eventual consistency |
