"""Unit tests for the function code of both clouds (no cloud SDKs or credentials needed)."""

import importlib.util
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(path: pathlib.Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ingest = _load(ROOT / "aws/src/ingest.py", "ingest")
processor = _load(ROOT / "aws/src/processor.py", "processor")
azure_orders = _load(ROOT / "azure/function_app/orders.py", "azure_orders")

GOOD = {"customer_id": "c-1", "items": [{"sku": "A1", "qty": 2}]}


class FakeSQS:
    def __init__(self):
        self.sent = []

    def send_message(self, QueueUrl, MessageBody):  # noqa: N803 - boto3 signature
        self.sent.append((QueueUrl, json.loads(MessageBody)))


class ConditionalCheckFailedException(Exception):
    pass


class FakeTable:
    def __init__(self, fail_ids=(), duplicate_ids=()):
        self.items, self.fail_ids, self.duplicate_ids = [], set(fail_ids), set(duplicate_ids)

    def put_item(self, Item, ConditionExpression):  # noqa: N803
        oid = Item["order_id"]
        if oid in self.duplicate_ids:
            raise ConditionalCheckFailedException()
        if oid in self.fail_ids:
            raise RuntimeError("throttled")
        self.items.append(Item)


def test_validation_rules_identical_on_both_clouds():
    cases = [GOOD, {}, {"customer_id": "c", "items": []}, {"customer_id": "c", "items": [{"sku": "A", "qty": 0}]}]
    for case in cases:
        assert ingest.validate(case) == azure_orders.validate(case)


def test_ingest_accepts_valid_order(monkeypatch):
    monkeypatch.setenv("QUEUE_URL", "https://queue")
    sqs = FakeSQS()
    resp = ingest.handler({"body": json.dumps(GOOD)}, None, sqs=sqs)
    assert resp["statusCode"] == 202
    order_id = json.loads(resp["body"])["order_id"]
    assert sqs.sent == [("https://queue", {"order_id": order_id, **GOOD})]


def test_ingest_rejects_bad_input_without_enqueueing():
    sqs = FakeSQS()
    assert ingest.handler({"body": "not json"}, None, sqs=sqs)["statusCode"] == 400
    resp = ingest.handler({"body": json.dumps({"customer_id": 1, "items": [{"sku": "A", "qty": -1}]})}, None, sqs=sqs)
    assert resp["statusCode"] == 400 and len(json.loads(resp["body"])["errors"]) == 2
    assert sqs.sent == []


def _records(*ids):
    return {"Records": [{"messageId": f"m-{i}", "body": json.dumps({"order_id": i, **GOOD})} for i in ids]}


def test_processor_reports_only_failed_records():
    table = FakeTable(fail_ids={"2"})
    result = processor.handler(_records("1", "2", "3"), None, table=table)
    assert result == {"batchItemFailures": [{"itemIdentifier": "m-2"}]}
    assert [i["order_id"] for i in table.items] == ["1", "3"]


def test_processor_treats_duplicates_as_success():
    table = FakeTable(duplicate_ids={"1"})
    assert processor.handler(_records("1"), None, table=table) == {"batchItemFailures": []}
