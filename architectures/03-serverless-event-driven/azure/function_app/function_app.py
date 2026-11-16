"""Azure Functions (Python v2 model). Bindings authenticate with the app's managed identity:
ServiceBusConnection__fullyQualifiedNamespace and CosmosDBConnection__accountEndpoint are app settings."""

import json
import uuid

import azure.functions as func

from orders import validate

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


@app.route(route="orders", methods=["POST"])
@app.service_bus_queue_output(arg_name="out", queue_name="orders", connection="ServiceBusConnection")
def ingest(req: func.HttpRequest, out: func.Out[str]) -> func.HttpResponse:
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(json.dumps({"errors": ["body must be JSON"]}), status_code=400)
    errors = validate(body)
    if errors:
        return func.HttpResponse(json.dumps({"errors": errors}), status_code=400)
    order = {"id": str(uuid.uuid4()), **body}
    out.set(json.dumps(order))
    return func.HttpResponse(json.dumps({"order_id": order["id"]}), status_code=202)


@app.service_bus_queue_trigger(arg_name="msg", queue_name="orders", connection="ServiceBusConnection")
@app.cosmos_db_output(arg_name="doc", database_name="orders", container_name="orders", connection="CosmosDBConnection")
def processor(msg: func.ServiceBusMessage, doc: func.Out[func.Document]) -> None:
    # Upsert by id: redelivered messages overwrite the same document (idempotent).
    order = json.loads(msg.get_body().decode())
    doc.set(func.Document.from_dict({**order, "status": "RECEIVED"}))
