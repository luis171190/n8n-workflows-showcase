# Architecture — Voice AI Lead Qualifier

## Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│ SUBFLOW A — Lead Inbound                                            │
│                                                                     │
│  Webhook: New Lead (/webhook/new-lead)                              │
│       │                                                             │
│       ▼                                                             │
│  Validate + Enrich  ←── email format, phone E.164, domain lookup   │
│       │                                                             │
│       ▼                                                             │
│  Idempotency: Lead  ←── INSERT leads ON CONFLICT (email) DO NOTHING│
│       │                                                             │
│  Lead: New? ─── NO ──→ Respond 200 (already_queued)                │
│       │                                                             │
│       YES                                                           │
│       ▼                                                             │
│  DNC Check  ←── SELECT FROM dnc_list WHERE phone = $phone          │
│       │                                                             │
│  Lead: On DNC? ─── YES ──→ Lead: Mark DNC → Respond 200 (blocked) │
│       │                                                             │
│       NO                                                            │
│       ▼                                                             │
│  Compliance: Working Hours  ←── TZ-aware hour check + next-slot    │
│       │                                                             │
│  Lead: In Hours? ─── NO ──→ Queue: Out of Hours → Respond 202     │
│       │                                                             │
│       YES                                                           │
│       ▼                                                             │
│  Trigger Retell Call  ←── POST /v2/create-phone-call (continueOnFail)
│       │                                                             │
│  Persist Call Attempt  ←── INSERT call_attempts                    │
│       │                                                             │
│  Respond 200 (call_initiated)                                       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ SUBFLOW B — Post-Call Analysis (async callback from Retell)         │
│                                                                     │
│  Webhook: Retell Post-Call (/webhook/retell-post-call)              │
│       │                                                             │
│       ▼                                                             │
│  Idempotency: Call  ←── INSERT processed_calls ON CONFLICT → dup   │
│       │                                                             │
│  Parse Retell Payload  ←── extract transcript, duration, cost       │
│       │                                                             │
│  Switch: LLM Provider  ←── $env.LLM_PROVIDER                       │
│       │                    │                                        │
│  OpenAI: Analyze     Anthropic: Analyze  ←── structured JSON schema│
│       │                    │                                        │
│       └────────────────────┘                                        │
│       ▼                                                             │
│  Normalize + BANT Extract  ←── whitelist, safe defaults, score      │
│       │                                                             │
│  Update Lead + Insert Cost  ←── CTE: UPDATE leads + INSERT costs   │
│       │                                                             │
│  Route by Intent (Switch)                                           │
│       │         │         │                                         │
│      hot      warm      cold                                        │
│       │         │         │                                         │
│  GCal+Airtable  nurture_queue  Respond 200 (disqualified)          │
│       │         │                                                   │
│  Respond 200  Respond 200 (nurture_queued)                         │
│  (meeting_scheduled)                                                │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ SUBFLOW C — Queue Drainer (cron every 5 min)                        │
│                                                                     │
│  Cron: Every 5 min                                                  │
│       │                                                             │
│       ▼                                                             │
│  Drainer: Fetch Queue  ←── SELECT from call_queue WHERE             │
│                             status='WAITING' AND scheduled_at<=NOW()│
│       │                                                             │
│       ▼ (split items)                                               │
│  Drainer: Trigger Retell  ←── POST /v2/create-phone-call           │
│       │                                                             │
│       ▼                                                             │
│  Drainer: Update Queue Status                                        │
│       success → status='TRIGGERED'                                  │
│       fail    → retry_count++, scheduled_at += POWER(2,n)*15 min   │
│       retry_count>=10 → status='GAVE_UP'                           │
└─────────────────────────────────────────────────────────────────────┘
```

## Async Voice Flow

The voice call is **not synchronous** — n8n does not wait on the call to finish:

```
n8n Subflow A                  Retell AI                   n8n Subflow B
──────────────                 ──────────────              ──────────────
POST /v2/create-phone-call ──► dials lead
Persist Call Attempt
Respond 200 (call_initiated)
                               conversation happens
                               call ends
                               ◄── POST /webhook/retell-post-call
                                                            Idempotency check
                                                            Parse transcript
                                                            LLM analysis
                                                            Update lead + costs
                                                            Route by intent
```

This design means:
1. The lead submission API responds in milliseconds (the caller doesn't wait for a 5-minute conversation).
2. Subflow A and B are decoupled — a Retell outage doesn't break lead ingestion.
3. The post-call webhook can be replayed (idempotency on `retell_call_id`).

## BANT Decision Tree

```
Transcript
    │
    ▼ LLM analysis (structured JSON output)
    {
      bant: { budget, authority, need, timing },
      score: 0-10,
      intent: 'hot'|'warm'|'cold'|'disqualified',
      objections: [...],
      summary: "...",
      next_action: 'schedule_meeting'|'nurture'|'disqualify'
    }
    │
    ▼ Normalize + BANT Extract (Code node)
    ├── Whitelist each field against allowed values
    ├── Apply safe defaults on parse errors
    └── Reconcile intent ↔ next_action:
            hot          → next_action must be 'schedule_meeting'
            cold/dis.    → next_action must be 'disqualify'
            warm         → next_action can be 'nurture'
    │
    ▼ Route by Intent
    ├── hot  → Google Calendar (create event) + Airtable (create deal) → 200
    ├── warm → nurture_queue INSERT (step=1, scheduled_at=+1 day)     → 200
    └── cold → UPDATE leads SET status='disqualified'                 → 200
```

## Per-Node Data Table

| Node | Type | Input | Output |
|---|---|---|---|
| Webhook: New Lead | Webhook | HTTP POST body | raw lead object |
| Validate + Enrich | Code | raw lead | validated lead + enrichment flags |
| Idempotency: Lead | Postgres | email | lead.id or empty (dup) |
| Lead: New? | IF | postgres rows | branch: new / dup |
| DNC Check | Postgres | phone | dnc row or empty |
| Lead: On DNC? | IF | postgres rows | branch: blocked / clear |
| Lead: Mark DNC | Postgres | lead.id | UPDATE leads SET status='dnc' |
| Compliance: Working Hours | Code | lead + timezone | in_hours bool + next_slot |
| Lead: In Hours? | IF | in_hours | branch: queue / proceed |
| Queue: Out of Hours | Postgres | lead.id + next_slot | INSERT call_queue |
| Trigger Retell Call | HTTP | phone + agent_id | retell response (call_id) |
| Persist Call Attempt | Postgres | lead.id + call_id | INSERT call_attempts |
| Respond 200 | Respond to Webhook | status | HTTP 200/202 |
| Webhook: Retell Post-Call | Webhook | Retell callback body | raw call data |
| Idempotency: Call | Postgres | retell_call_id | row or empty (dup) |
| Parse Retell Payload | Code | raw call data | {transcript, duration, cost, lead_id} |
| Switch: LLM Provider | Switch | LLM_PROVIDER env | branch: openai / anthropic |
| OpenAI: Analyze Transcript | HTTP | transcript | raw JSON string |
| Anthropic: Analyze Transcript | HTTP | transcript | raw JSON string |
| Normalize + BANT Extract | Code | raw LLM output | normalized BANT object |
| Update Lead + Insert Cost | Postgres | BANT + lead.id | CTE: leads + call_costs |
| Route by Intent | Switch | intent | branch: hot / warm / cold |
| GCal: Create Event | HTTP | lead + summary | Google Calendar event |
| Airtable: Create Deal | HTTP | lead + BANT | Airtable record |
| nurture_queue INSERT | Postgres | lead.id | nurture_queue row |
| Cron: Every 5 min | Schedule | — | trigger |
| Drainer: Fetch Queue | Postgres | — | call_queue rows |
| Drainer: Trigger Retell | HTTP | queue row | Retell response |
| Drainer: Update Queue Status | Postgres | result | UPDATE call_queue |

## Failure Modes

| Failure | Detection | Recovery |
|---|---|---|
| Duplicate lead submission | `INSERT ON CONFLICT DO NOTHING` returns 0 rows | 200 `already_queued`, no side-effects |
| Lead on DNC | SELECT dnc_list | 200 `blocked`, UPDATE leads SET status='dnc' |
| Call outside hours | TZ-aware hour check | 202, INSERT call_queue with next working-hour slot |
| Retell API down (Subflow A) | `continueOnFail: true` on Trigger Retell Call | INSERT call_queue reason='retry', drainer picks up |
| Duplicate post-call webhook | `INSERT processed_calls ON CONFLICT` returns 0 rows | 200 `already_processed`, no analysis re-run |
| LLM returns malformed JSON | try/catch in Normalize node | Safe default BANT object, intent='warm', logged |
| Retell rate limit (drainer) | HTTP 429 from drainer trigger | retry_count++, exponential backoff, GAVE_UP at 10 |
| Google Calendar fail | continueOnFail | lead still marked 'hot', manual follow-up needed |

## Cost Tracking

Each call produces two cost components persisted in `call_costs`:

| Component | Source | Typical cost |
|---|---|---|
| `cost_usd` | Retell API response field | ~$0.02–$0.08/min |
| `analysis_cost_usd` | Estimated from token count | ~$0.001–$0.005/call (gpt-4o-mini) |

Rollup query:

```sql
SELECT
    DATE(recorded_at)           AS day,
    COUNT(*)                    AS calls,
    SUM(cost_usd)               AS retell_cost,
    SUM(analysis_cost_usd)      AS llm_cost,
    SUM(cost_usd + COALESCE(analysis_cost_usd, 0)) AS total_cost
FROM call_costs
GROUP BY 1
ORDER BY 1 DESC;
```
