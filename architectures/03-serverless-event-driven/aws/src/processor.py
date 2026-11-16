"""SQS -> DynamoDB: persist orders idempotently. Failed records are reported individually
(ReportBatchItemFailures) so only they are retried and, after maxReceiveCount, go to the DLQ."""

import json
import os


def handler(event, context, table=None):
    if table is None:  # pragma: no cover
        import boto3

        table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    failures = []
    for record in event.get("Records", []):
        try:
            order = json.loads(record["body"])
            table.put_item(
                Item={"pk": f"ORDER#{order['order_id']}", **order, "status": "RECEIVED"},
                ConditionExpression="attribute_not_exists(pk)",  # idempotent on redelivery
            )
        except Exception as exc:  # noqa: BLE001 - any failure -> retry this record only
            if type(exc).__name__ == "ConditionalCheckFailedException":
                continue  # already stored: duplicate delivery
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
