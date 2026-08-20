import os
import time

import requests
from flask import Flask, jsonify

app = Flask(__name__)

PAYMENT_SVC_URL = os.getenv("PAYMENT_SVC_URL", "http://payment-svc:5000")


@app.route("/health")
def health():
    return jsonify(status="ok")


@app.route("/order", methods=["POST"])
def place_order():
    """Places an order by calling payment-svc. This is the request that
    load-generator hits once a second, and the one whose latency/error rate
    you'll watch move in both Datadog and groundcover during the demo."""
    try:
        resp = requests.post(
            f"{PAYMENT_SVC_URL}/charge",
            json={"amount": 42.00},
            timeout=5,
        )
        resp.raise_for_status()
        return (
            jsonify(
                order_id="ord-" + str(int(time.time() * 1000)),
                status="confirmed",
                payment=resp.json(),
            ),
            200,
        )
    except requests.exceptions.RequestException as e:
        return jsonify(status="failed", error=str(e)), 502


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
