# 03 · Serverless, event-driven order intake

**Problem:** accept orders over HTTP with unpredictable spikes, never lose an accepted order, and pay nothing when idle.

**Approach:** an API that **validates and enqueues** (fast 202), a queue that **absorbs bursts**, a worker that writes **idempotently**, and poison messages that go to a **dead-letter queue** with an alarm.

## AWS

```mermaid
flowchart LR
  c([Client]) -->|POST /orders<br/>IAM auth · throttled| api[API Gateway<br/>HTTP API]
  api --> ing[Lambda: ingest<br/>validate → 202]
  ing -->|SendMessage only| q[[SQS orders<br/>SSE]]
  q -->|batch 10<br/>partial failures| proc[Lambda: processor]
  proc -->|PutItem<br/>attribute_not_exists| ddb[(DynamoDB<br/>on-demand · PITR)]
  q -->|after 5 receives| dlq[[SQS DLQ<br/>14 days]]
  dlq -.-> alarm[CloudWatch alarm]
  ing & proc -.-> xr[X-Ray · JSON logs]
```

## Azure

```mermaid
flowchart LR
  c([Client]) -->|POST /api/orders<br/>function key / Entra ID| ing[Function: ingest<br/>Flex Consumption]
  ing -->|managed identity<br/>Data Sender| q[[Service Bus queue<br/>local auth off]]
  q -->|managed identity<br/>Data Receiver| proc[Function: processor]
  proc -->|managed identity<br/>container-scoped RBAC| cos[(Cosmos DB serverless<br/>keys disabled · continuous backup)]
  q -->|after 5 deliveries| dlq[[Dead-letter sub-queue]]
  dlq -.-> alert[Azure Monitor alert]
  ing & proc -.-> ai[Application Insights<br/>Entra ID auth]
```

## Decisions

| Decision | Reason |
|---|---|
| Validate at the edge, process asynchronously | The client gets a fast 202 and the worker scales independently |
| Idempotent writes (`attribute_not_exists` / upsert by id) | Queues deliver **at least once** |
| Partial batch failure reporting (AWS) | One bad record doesn't make nine good ones retry |
| Five attempts, then dead-letter, then alarm | Bounded retries; humans look at true poison messages |
| **No keys anywhere (Azure):** Service Bus, Cosmos DB and Storage reject key auth; the function uses managed identity with queue- and container-scoped roles | Nothing to leak or rotate |
| One IAM role per Lambda, with only the actions it needs | Blast radius of a compromised function is one queue or table |

## Tests

- `terraform test` (both clouds): reliability settings, least privilege (no wildcards, ingest can't touch the database, RBAC scopes), and on Azure that **no key-based auth** is enabled anywhere.
- `pytest app_tests/`: handler behaviour with fakes (validation, 202 path, partial-failure reporting, duplicate handling), and that **validation rules are identical on both clouds**.

## Deploy the Azure function code

```bash
cd azure/function_app && func azure functionapp publish func-orders --python
```
