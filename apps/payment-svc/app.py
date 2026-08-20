import os
import random
import time

from flask import Flask, jsonify, request

app = Flask(__name__)

# In-memory chaos state — toggled live during the workshop via POST /chaos.
# Single replica, so this is intentionally not persisted anywhere.
chaos_state = {
    "latency_ms": int(os.getenv("CHAOS_LATENCY_MS", "0")),
    "error_rate": float(os.getenv("CHAOS_ERROR_RATE", "0.0")),
}


@app.route("/health")
def health():
    return jsonify(status="ok")


@app.route("/chaos", methods=["GET"])
def get_chaos():
    return jsonify(chaos_state)


@app.route("/chaos", methods=["POST"])
def set_chaos():
    """Flip this mid-workshop to show both dashboards react live, e.g.:
    curl -X POST http://<payment-svc>/chaos -d '{"latency_ms": 800, "error_rate": 0.3}'
    """
    body = request.get_json(force=True)
    if "latency_ms" in body:
        chaos_state["latency_ms"] = int(body["latency_ms"])
    if "error_rate" in body:
        chaos_state["error_rate"] = float(body["error_rate"])
    return jsonify(chaos_state)


@app.route("/charge", methods=["POST"])
def charge():
    if chaos_state["latency_ms"] > 0:
        time.sleep(chaos_state["latency_ms"] / 1000.0)

    if random.random() < chaos_state["error_rate"]:
        return jsonify(status="declined", reason="simulated processing error"), 500

    amount = (request.get_json(silent=True) or {}).get("amount", 0)
    return (
        jsonify(
            status="approved",
            amount=amount,
            transaction_id="txn-" + str(random.randint(100000, 999999)),
        ),
        200,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
