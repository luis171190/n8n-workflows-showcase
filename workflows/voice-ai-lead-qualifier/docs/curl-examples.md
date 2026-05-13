# Curl examples — voice-ai-lead-qualifier

> Replace `https://your-n8n.example.com` with your n8n instance.
> Two webhook paths:
>   - `/webhook/new-lead`         — Subflow A (lead inbound)
>   - `/webhook/retell-post-call` — Subflow B (Retell callback)

These examples simulate the full lifecycle: lead arrives → call triggers → post-call analysis → CRM routing.

---

## 1. New lead — happy path (in-hours, not on DNC)

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/new-lead \
  -H "Content-Type: application/json" \
  -d '{
    "email": "jane.doe@acmecorp.com",
    "phone": "+15551234567",
    "first_name": "Jane",
    "last_name": "Doe",
    "company": "Acme Corp",
    "source": "landing_page"
  }'
```

**Response (HTTP 200):**

```json
{
  "status": "ok",
  "action": "call_initiated",
  "lead_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "call_attempt_id": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
}
```

**Side-effects:**
- 1 row inserted in `leads` (status='calling').
- 1 row inserted in `call_attempts` (status='initiated').
- Retell API called: outbound call placed to `+15551234567`.

---

## 2. Lead on DNC — blocked

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/new-lead \
  -H "Content-Type: application/json" \
  -d '{
    "email": "blocked@example.com",
    "phone": "+15550000000",
    "first_name": "Test",
    "source": "webinar"
  }'
```

Pre-condition: `+15550000000` is the seed DNC entry from the SQL schema.

**Response (HTTP 200):**

```json
{ "status": "blocked", "reason": "phone_on_dnc" }
```

**Side-effects:**
- 1 row in `leads` with `status='dnc'`.
- No `call_attempts` row. No Retell call.

---

## 3. Lead out of hours — queued

Simulate business hours = 09:00-18:00 America/New_York. Run this after 18:00 ET or on a weekend.

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/new-lead \
  -H "Content-Type: application/json" \
  -d '{
    "email": "outofhours@startupxyz.io",
    "phone": "+15559876543",
    "first_name": "Bob",
    "company": "Startup XYZ",
    "source": "referral"
  }'
```

**Response (HTTP 202):**

```json
{
  "status": "queued",
  "reason": "out_of_hours",
  "scheduled_at": "2026-05-14T13:00:00.000Z",
  "queue_id": "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"
}
```

**Side-effects:**
- 1 row in `leads` (status='queued').
- 1 row in `call_queue` (reason='out_of_hours', scheduled_at = next working-hour start).
- Drainer cron picks it up within 5 minutes of scheduled_at.

---

## 4. Retell post-call webhook — HOT lead (score 8)

Simulate the callback that Retell sends after a call ends. Include a transcript with strong buying signals.

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/retell-post-call \
  -H "Content-Type: application/json" \
  -d '{
    "call_id": "retell_call_ABCD1234",
    "from_number": "+15551234567",
    "to_number": "+15559990001",
    "duration": 187,
    "call_status": "ended",
    "cost": 0.062,
    "metadata": {
      "lead_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    },
    "transcript": "Agent: Hi, am I speaking with Jane from Acme Corp?\nJane: Yes, speaking.\nAgent: Great! I'\''m calling about our AI automation platform. Are you currently evaluating any solutions?\nJane: Actually yes, we have budget approved for Q3, around $50k. I'\''m the VP of Ops so I can sign off. We really need this now, our manual processes are killing us.\nAgent: That sounds like a great fit. Would you be open to a demo this week?\nJane: Absolutely, let'\''s do Thursday afternoon."
  }'
```

**Response (HTTP 200):**

```json
{
  "status": "ok",
  "lead_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "intent": "hot",
  "bant_score": 9,
  "next_action": "schedule_meeting",
  "calendar_event_id": "google_event_xyz",
  "airtable_record_id": "recABCDEFGH"
}
```

**Side-effects:**
- `leads` updated: intent='hot', bant_score=9, status='called'.
- 1 row in `call_costs`.
- Google Calendar event created.
- Airtable Deals record created.

---

## 5. Retell post-call — WARM lead (score 5, nurture)

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/retell-post-call \
  -H "Content-Type: application/json" \
  -d '{
    "call_id": "retell_call_WARM001",
    "from_number": "+15559876543",
    "to_number": "+15559990001",
    "duration": 142,
    "call_status": "ended",
    "cost": 0.047,
    "metadata": {
      "lead_id": "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"
    },
    "transcript": "Agent: Hi Bob, calling from TechCo about our automation platform.\nBob: Oh hi, yeah I saw your ad. We might be interested but budget is a bit uncertain right now. Maybe in 3-4 months.\nAgent: Totally understand. What are your main pain points today?\nBob: We do a lot of manual data entry. It'\''s a problem but the CTO needs to approve any spend.\nAgent: Got it. Would it be okay if we followed up with some case studies?\nBob: Sure, that'\''s fine."
  }'
```

**Response (HTTP 200):**

```json
{
  "status": "ok",
  "lead_id": "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz",
  "intent": "warm",
  "bant_score": 5,
  "next_action": "nurture",
  "nurture_step": 1,
  "nurture_scheduled_at": "2026-05-14T09:00:00.000Z"
}
```

**Side-effects:**
- `leads` updated: intent='warm', bant_score=5.
- `nurture_queue` row inserted (step=1, scheduled_at=+1 day at working-hour start).

---

## 6. Idempotency replay — same call_id

Replay request 4 with the same `call_id`:

```bash
curl -sS -X POST https://your-n8n.example.com/webhook/retell-post-call \
  -H "Content-Type: application/json" \
  -d '{
    "call_id": "retell_call_ABCD1234",
    "transcript": "... same or different ...",
    "cost": 0.062
  }'
```

**Response (HTTP 200):**

```json
{ "status": "already_processed" }
```

The `processed_calls` table has a PRIMARY KEY on `retell_call_id`. The INSERT short-circuits and no analysis re-runs. Critical for avoiding double BANT scoring if Retell retries the callback.

---

## Inspect costs per day

```sql
SELECT
    DATE(recorded_at)           AS day,
    COUNT(*)                    AS calls,
    ROUND(SUM(cost_usd)::NUMERIC, 4)               AS retell_usd,
    ROUND(SUM(analysis_cost_usd)::NUMERIC, 6)      AS llm_usd,
    ROUND(SUM(cost_usd + COALESCE(analysis_cost_usd,0))::NUMERIC, 4) AS total_usd
FROM call_costs
GROUP BY 1
ORDER BY 1 DESC;
```

## Inspect lead funnel

```sql
SELECT
    status,
    intent,
    COUNT(*)        AS leads,
    AVG(bant_score) AS avg_score
FROM leads
GROUP BY status, intent
ORDER BY status, intent;
```

## Postman collection

[./postman-collection.json](./postman-collection.json) — 6 requests with automated tests covering: DNC block, out-of-hours queue, hot/warm/cold routing, idempotency replay.
