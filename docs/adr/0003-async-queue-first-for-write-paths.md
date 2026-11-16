# ADR-0003: Queue-first, idempotent processing for write-heavy APIs

- **Status:** Accepted
- **Context:** Synchronous writes to the database during traffic spikes caused throttling and lost requests.
- **Decision:** APIs validate and enqueue (202 Accepted). Workers process idempotently with bounded retries and a dead-letter queue with an alarm.
- **Consequences:** Clients need an asynchronous model (order id now, status later). Eventual consistency is acceptable for this domain. Operations must own the DLQ runbook.
