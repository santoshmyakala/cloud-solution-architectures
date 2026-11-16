"""Cloud-agnostic order validation shared with the AWS implementation's rules."""

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
