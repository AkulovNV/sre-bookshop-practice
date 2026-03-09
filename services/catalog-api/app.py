"""
Catalog API — сервис каталога книг Bookshop.

Endpoints:
  GET  /books          — список всех книг
  GET  /books/<id>     — книга по ID
  GET  /books/search   — поиск по автору/названию
  GET  /healthz        — liveness probe
  GET  /ready          — readiness probe (проверяет БД)
  GET  /metrics        — Prometheus метрики
"""
import os
import time
import logging
import json
from functools import wraps

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
SERVICE_NAME = os.environ.get("SERVICE_NAME", "catalog-api")

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

# ---------------------------------------------------------------------------
# Structured JSON logging с TraceID для корреляции с Loki
# ---------------------------------------------------------------------------
class TraceIDFormatter(logging.Formatter):
    def format(self, record):
        span = trace.get_current_span()
        ctx = span.get_span_context() if span else None
        trace_id = format(ctx.trace_id, '032x') if ctx and ctx.trace_id else ""
        span_id = format(ctx.span_id, '016x') if ctx and ctx.span_id else ""
        log = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "message": record.getMessage(),
            "service": SERVICE_NAME,
            "traceID": trace_id,
            "spanID": span_id,
        }
        return json.dumps(log)

handler = logging.StreamHandler()
handler.setFormatter(TraceIDFormatter())
app.logger.handlers = [handler]
app.logger.setLevel(logging.INFO)

# Instrument Flask
FlaskInstrumentor().instrument_app(app, excluded_urls="healthz,ready,metrics")

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://bookshop:changeme-in-production@postgres:5432/bookshop"
)

# ---------------------------------------------------------------------------
# Prometheus метрики — основа для SLI
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
DB_QUERY_DURATION = Histogram(
    "db_query_duration_seconds",
    "Database query duration in seconds",
    ["query_type"],
    buckets=[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0]
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
    """Получение соединения с БД (per-request)."""
    if "db" not in g:
        try:
            g.db = psycopg2.connect(DATABASE_URL, cursor_factory=RealDictCursor)
            g.db.autocommit = True
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

def query_db(sql, params=None, query_type="select"):
    """Выполнение запроса к БД с измерением latency."""
    start = time.monotonic()
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute(sql, params)
        result = cur.fetchall()
        return result
    finally:
        duration = time.monotonic() - start
        DB_QUERY_DURATION.labels(query_type=query_type).observe(duration)

# ---------------------------------------------------------------------------
# Middleware — сбор метрик для каждого запроса
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
        REQUEST_DURATION.labels(
            method=request.method,
            endpoint=endpoint
        ).observe(duration)
        REQUEST_COUNT.labels(
            method=request.method,
            endpoint=endpoint,
            status=response.status_code
        ).inc()
        # Structured log для корреляции с трейсами (исключаем probes и metrics)
        if endpoint not in ("healthz", "ready", "metrics"):
            app.logger.info(
                "%s %s %s %.3fs",
                request.method, request.path, response.status_code, duration
            )
    IN_PROGRESS.dec()
    return response

# ---------------------------------------------------------------------------
# Health checks — для Kubernetes probes
# ---------------------------------------------------------------------------
@app.route("/healthz")
def healthz():
    """Liveness probe — проверяем, что процесс жив."""
    return jsonify({"status": "alive", "service": SERVICE_NAME}), 200

@app.route("/ready")
def ready():
    """Readiness probe — проверяем подключение к БД."""
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        return jsonify({"status": "ready", "service": SERVICE_NAME, "db": "connected"}), 200
    except Exception as e:
        return jsonify({"status": "not_ready", "service": SERVICE_NAME, "error": str(e)}), 503

# ---------------------------------------------------------------------------
# Prometheus metrics endpoint
# ---------------------------------------------------------------------------
@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------
@app.route("/books")
def list_books():
    """Список всех книг."""
    try:
        books = query_db("SELECT id, title, author, isbn, price, stock FROM books ORDER BY id")
        return jsonify({"books": [dict(b) for b in books], "count": len(books)}), 200
    except Exception as e:
        app.logger.error(f"Error listing books: {e}")
        return jsonify({"error": "internal_server_error"}), 500

@app.route("/books/<int:book_id>")
def get_book(book_id):
    """Книга по ID."""
    try:
        books = query_db("SELECT id, title, author, isbn, price, stock FROM books WHERE id = %s", (book_id,))
        if not books:
            return jsonify({"error": "not_found", "message": f"Book {book_id} not found"}), 404
        return jsonify({"book": dict(books[0])}), 200
    except Exception as e:
        app.logger.error(f"Error getting book {book_id}: {e}")
        return jsonify({"error": "internal_server_error"}), 500

@app.route("/books/search")
def search_books():
    """Поиск книг по автору или названию."""
    q = request.args.get("q", "")
    if not q:
        return jsonify({"error": "bad_request", "message": "Query parameter 'q' required"}), 400
    try:
        pattern = f"%{q}%"
        books = query_db(
            "SELECT id, title, author, isbn, price, stock FROM books WHERE title ILIKE %s OR author ILIKE %s ORDER BY id",
            (pattern, pattern),
            query_type="search"
        )
        return jsonify({"books": [dict(b) for b in books], "query": q, "count": len(books)}), 200
    except Exception as e:
        app.logger.error(f"Error searching books: {e}")
        return jsonify({"error": "internal_server_error"}), 500

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
