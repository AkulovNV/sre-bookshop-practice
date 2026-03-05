"""
Order API — сервис заказов Bookshop.

Endpoints:
  GET   /orders         — список заказов
  POST  /orders         — создание заказа
  GET   /orders/<id>    — заказ по ID
  GET   /healthz        — liveness probe
  GET   /ready          — readiness probe
  GET   /metrics        — Prometheus метрики
"""
import os
import time
import json
import logging

from flask import Flask, jsonify, request, g
import psycopg2
from psycopg2.extras import RealDictCursor
from prometheus_client import (
    Counter, Histogram, Gauge,
    generate_latest, CONTENT_TYPE_LATEST
)

# ---------------------------------------------------------------------------
# OpenTelemetry
# ---------------------------------------------------------------------------
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")
SERVICE_NAME = os.environ.get("SERVICE_NAME", "order-api")

resource = Resource.create({"service.name": SERVICE_NAME})
provider = TracerProvider(resource=resource)

if OTEL_ENDPOINT:
    exporter = OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))

trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

# Instrument psycopg2
Psycopg2Instrumentor().instrument()

# ---------------------------------------------------------------------------
# Конфигурация
# ---------------------------------------------------------------------------
app = Flask(__name__)
app.logger.setLevel(logging.INFO)

# Instrument Flask
FlaskInstrumentor().instrument_app(app)

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://bookshop:changeme-in-production@postgres:5432/bookshop"
)

# ---------------------------------------------------------------------------
# Prometheus метрики
# ---------------------------------------------------------------------------
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"]
)
REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "endpoint"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
)
ORDER_CREATED = Counter(
    "orders_created_total",
    "Total orders created",
    ["status"]
)
ORDER_TOTAL_AMOUNT = Histogram(
    "order_total_amount",
    "Order total amount distribution",
    buckets=[10, 25, 50, 100, 250, 500, 1000]
)
IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "Number of HTTP requests in progress"
)
DB_CONNECTIONS_ERRORS = Counter(
    "db_connection_errors_total",
    "Total database connection errors"
)

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
def get_db():
    if "db" not in g:
        try:
            g.db = psycopg2.connect(DATABASE_URL, cursor_factory=RealDictCursor)
        except psycopg2.Error as e:
            DB_CONNECTIONS_ERRORS.inc()
            app.logger.error(f"Database connection failed: {e}")
            raise
    return g.db

@app.teardown_appcontext
def close_db(exception):
    db = g.pop("db", None)
    if db is not None:
        db.close()

# ---------------------------------------------------------------------------
# Middleware
# ---------------------------------------------------------------------------
@app.before_request
def before_request():
    g.start_time = time.monotonic()
    IN_PROGRESS.inc()

@app.after_request
def after_request(response):
    if hasattr(g, "start_time"):
        duration = time.monotonic() - g.start_time
        endpoint = request.endpoint or "unknown"
        REQUEST_DURATION.labels(method=request.method, endpoint=endpoint).observe(duration)
        REQUEST_COUNT.labels(method=request.method, endpoint=endpoint, status=response.status_code).inc()
    IN_PROGRESS.dec()
    return response

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------
@app.route("/healthz")
def healthz():
    return jsonify({"status": "alive", "service": SERVICE_NAME}), 200

@app.route("/ready")
def ready():
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        return jsonify({"status": "ready", "service": SERVICE_NAME}), 200
    except Exception as e:
        return jsonify({"status": "not_ready", "error": str(e)}), 503

@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------
@app.route("/orders")
def list_orders():
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("""
            SELECT id, customer, status, total, created_at, updated_at
            FROM orders ORDER BY created_at DESC LIMIT 50
        """)
        orders = cur.fetchall()
        return jsonify({"orders": [dict(o) for o in orders], "count": len(orders)}), 200
    except Exception as e:
        app.logger.error(f"Error listing orders: {e}")
        return jsonify({"error": "internal_server_error"}), 500

@app.route("/orders", methods=["POST"])
def create_order():
    try:
        data = request.get_json()
        if not data or "customer" not in data or "items" not in data:
            return jsonify({"error": "bad_request", "message": "customer and items required"}), 400

        conn = get_db()
        cur = conn.cursor()

        # Рассчитываем total
        total = 0
        for item in data["items"]:
            cur.execute("SELECT price, stock FROM books WHERE id = %s", (item["book_id"],))
            book = cur.fetchone()
            if not book:
                return jsonify({"error": "not_found", "message": f"Book {item['book_id']} not found"}), 404
            if book["stock"] < item.get("quantity", 1):
                return jsonify({"error": "conflict", "message": f"Insufficient stock for book {item['book_id']}"}), 409
            total += float(book["price"]) * item.get("quantity", 1)

        # Создаём заказ
        cur.execute(
            "INSERT INTO orders (customer, status, total) VALUES (%s, 'pending', %s) RETURNING id",
            (data["customer"], total)
        )
        order_id = cur.fetchone()["id"]

        # Добавляем позиции
        for item in data["items"]:
            cur.execute("SELECT price FROM books WHERE id = %s", (item["book_id"],))
            book = cur.fetchone()
            qty = item.get("quantity", 1)
            cur.execute(
                "INSERT INTO order_items (order_id, book_id, quantity, price) VALUES (%s, %s, %s, %s)",
                (order_id, item["book_id"], qty, book["price"])
            )
            # Уменьшаем stock
            cur.execute("UPDATE books SET stock = stock - %s WHERE id = %s", (qty, item["book_id"]))

        conn.commit()
        ORDER_CREATED.labels(status="success").inc()
        ORDER_TOTAL_AMOUNT.observe(total)

        return jsonify({"order": {"id": order_id, "status": "pending", "total": total}}), 201

    except Exception as e:
        ORDER_CREATED.labels(status="error").inc()
        app.logger.error(f"Error creating order: {e}")
        return jsonify({"error": "internal_server_error"}), 500

@app.route("/orders/<int:order_id>")
def get_order(order_id):
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT id, customer, status, total, created_at FROM orders WHERE id = %s", (order_id,))
        order = cur.fetchone()
        if not order:
            return jsonify({"error": "not_found"}), 404

        cur.execute("""
            SELECT oi.quantity, oi.price, b.title, b.author
            FROM order_items oi JOIN books b ON oi.book_id = b.id
            WHERE oi.order_id = %s
        """, (order_id,))
        items = cur.fetchall()

        result = dict(order)
        result["items"] = [dict(i) for i in items]
        return jsonify({"order": result}), 200
    except Exception as e:
        app.logger.error(f"Error getting order {order_id}: {e}")
        return jsonify({"error": "internal_server_error"}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
