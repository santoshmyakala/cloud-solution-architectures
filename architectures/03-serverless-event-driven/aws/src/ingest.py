"""HTTP API -> SQS: validate an order and enqueue it. Returns 202 with the order id."""

import json
import os
import uuid

REQUIRED = {"customer_id": str, "items": list}


def validate(body: dict) -> list[str]:
    errors = [f"'{k}' is required and must be {t.__name__}" for k, t in REQUIRED.items() if not isinstance(body.get(k), t)]
    if isinstance(body.get("items"), list):
        if not body["items"]:
            errors.append("'items' must not be empty")
        for i, item in enumerate(body["items"]):
            if not (isinstance(item, dict) and isinstance(item.get("sku"), str) and isinstance(item.get("qty"), int) and item["qty"] > 0):
                errors.append(f"items[{i}] needs a string 'sku' and a positive integer 'qty'")
    return errors


def handler(event, context, sqs=None):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return {"statusCode": 400, "body": json.dumps({"errors": ["body must be JSON"]})}
    errors = validate(body)
    if errors:
        return {"statusCode": 400, "body": json.dumps({"errors": errors})}

    order = {"order_id": str(uuid.uuid4()), **body}
    if sqs is None:  # pragma: no cover - real client only inside Lambda
        import boto3

        sqs = boto3.client("sqs")
    sqs.send_message(QueueUrl=os.environ["QUEUE_URL"], MessageBody=json.dumps(order))
    return {"statusCode": 202, "body": json.dumps({"order_id": order["order_id"]})}
