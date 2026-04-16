# Практика: Приложение «Bookshop»

## Архитектура

```
                           ┌──────────────────────────────────────────┐
                           │         monitoring namespace             │
                           │                                          │
                           │  ┌────────────┐     ┌──────────┐        │
                           │  │ Prometheus  │◄────│  Tempo   │        │
                           │  │  (scrape)   │ rw  │  :4317   │        │
                           │  └─────┬──────┘     └────▲─────┘        │
                           │        │                  │ OTLP         │
                           │  ┌─────▼──────┐          │              │
                           │  │  Grafana   │          │              │
                           │  │  :3000     │          │              │
                           │  └────────────┘          │              │
                           └──────────────────────────┼──────────────┘
                                                      │
                    ┌─────────────┐                    │
                    │   Ingress   │                    │
                    │  /bookshop  │                    │
                    └──────┬──────┘                    │
                           │                          │
                    ┌──────▼──────┐                    │
                    │   frontend  │                    │
                    │  (nginx)    │                    │
                    │  Port: 80   │                    │
                    └───┬─────┬───┘                    │
                        │     │                        │
              ┌─────────▼┐   ┌▼──────────┐            │
              │catalog-api│   │ order-api  │──── OTLP ─┘
              │ (Python)  │   │ (Python)   │
              │ Port: 8080│   │ Port: 8080 │
              │ + OTel SDK│   │ + OTel SDK │
              └─────┬─────┘   └─────┬──────┘
                    │               │
                    └───────┬───────┘
                     ┌──────▼──────┐
                     │  PostgreSQL  │
                     │ (StatefulSet)│
                     │  Port: 5432  │
                     └─────────────┘
```

## Компоненты

| Сервис       | Тип          | Образ                          | Порт |
|--------------|--------------|--------------------------------|------|
| frontend     | Deployment   | nginx:1.25-alpine              | 80   |
| catalog-api  | Deployment   | python:3.12-slim (+ OTel SDK)  | 8080 |
| order-api    | Deployment   | python:3.12-slim (+ OTel SDK)  | 8080 |
| postgres     | StatefulSet  | postgres:16-alpine             | 5432 |

### Стек наблюдаемости

| Компонент                | Назначение                                     | Установка      |
|--------------------------|-------------------------------------------------|----------------|
| kube-prometheus-stack    | Prometheus + Grafana + Alertmanager             | Helm           |
| Grafana Tempo            | Backend для distributed traces                  | Helm           |
| OpenTelemetry SDK        | Инструментация приложения (Flask, psycopg2)     | В коде (Python)|

## Быстрый старт

```bash
# 1. Создать namespace
kubectl apply -f manifests/00-namespace.yaml

# 2. Развернуть всё приложение
kubectl apply -f manifests/

# 3. Проверить статус
kubectl get all -n bookshop

# 4. Дождаться готовности
kubectl rollout status deploy/frontend -n bookshop
kubectl rollout status deploy/catalog-api -n bookshop
kubectl rollout status deploy/order-api -n bookshop
kubectl rollout status statefulset/postgres -n bookshop
```

## Структура репозитория

```
manifests/                                # K8s манифесты (kubectl apply -f manifests/)
├── 00-namespace.yaml                  # Namespace + ResourceQuota
├── 01-postgres-secret.yaml            # Credentials для PostgreSQL
├── 02-postgres.yaml                   # StatefulSet + Service + PDB
├── 04-catalog-api.yaml                # Deployment + Service + HPA + PDB
├── 06-order-api.yaml                  # Deployment + Service + HPA + PDB
├── 08-frontend.yaml                   # Deployment + Service + HPA + PDB
├── 09-ingress.yaml                    # Ingress для внешнего доступа
├── 10-network-policies.yaml           # NetworkPolicy (deny-by-default + whitelist)
├── 11-monitoring.yaml                 # ServiceMonitor + PrometheusRule (SLO)
├── 12-grafana-dashboard.yaml          # Grafana dashboard (ConfigMap sidecar)
├── 22-grafana-tempo-datasource.yaml   # Tempo datasource для Grafana (ConfigMap)
└── 23-monitoring-ingress.yaml         # Ingress для Grafana, Prometheus, Alertmanager

helm-values/                              # Helm values (НЕ K8s манифесты)
├── ingress-nginx.yaml                 # Values для ingress-nginx controller
├── kube-prometheus-stack.yaml         # Values для kube-prometheus-stack
├── tempo.yaml                         # Values для Grafana Tempo
└── grafana.yaml                       # Values для standalone Grafana (справочно)

services/
├── catalog-api/
│   ├── app.py                         # Flask + Prometheus + OpenTelemetry
│   └── requirements.txt
├── order-api/
│   ├── app.py                         # Flask + Prometheus + OpenTelemetry
│   └── requirements.txt
└── frontend/
    ├── nginx.conf
    └── index.html

scripts/
├── 01-cartography.sh                  # Инвентаризация ресурсов в кластере
├── 02-deploy.sh                       # Последовательный деплой приложения
├── 03-check-slo.sh                    # Проверка SLO и метрик
├── 04-install-monitoring.sh           # Установка стека мониторинга
├── 05-generate-traffic.sh             # Генерация трафика и исследование трейсов
└── 99-cleanup.sh                      # Удаление всех ресурсов

docs/
├── slo-template.md                    # Шаблон SLO-документа
├── discussion-questions.md            # Вопросы для обсуждения
└── lecture-02/                        # Материалы лекции 2
```

---

## Сценарий практики — SLO и деплой

### Шаг 1. Картография
```bash
bash scripts/01-cartography.sh
```

### Шаг 2. Деплой
```bash
bash scripts/02-deploy.sh
```

### Шаг 3. Определение SLO
```bash
cat docs/slo-template.md
cat manifests/11-monitoring.yaml
bash scripts/03-check-slo.sh
```

---

## Сценарий практики — Наблюдаемость и трейсинг

> **Предусловие:** приложение Bookshop должно быть задеплоено (Шаги 1-3 из Лекции 1).

### Шаг 4. Установка стека мониторинга

Установка ingress-nginx, kube-prometheus-stack (Prometheus + Grafana + Alertmanager) и Grafana Tempo:

```bash
bash scripts/04-install-monitoring.sh
```

**Что происходит:**
1. Добавляются Helm-репозитории `ingress-nginx`, `prometheus-community` и `grafana`
2. Устанавливается `ingress-nginx` — Ingress Controller с LoadBalancer (External IP)
3. Устанавливается `kube-prometheus-stack` с настройками из `helm-values/kube-prometheus-stack.yaml`:
   - Prometheus с включённым remote write receiver (для Tempo Metrics Generator)
   - Grafana с sidecar для автоподхвата дашбордов и datasources из ConfigMap
   - Alertmanager
4. Устанавливается `grafana/tempo` с настройками из `helm-values/tempo.yaml`:
   - OTLP gRPC приёмник на порту 4317
   - Metrics Generator: автоматические service graphs и span metrics
   - Remote write метрик в Prometheus
5. Добавляется Tempo datasource в Grafana через ConfigMap sidecar
6. Загружается Grafana dashboard «Bookshop — API Services»
7. Создаются Ingress для мониторинга и приложения
8. Применяются ServiceMonitor и PrometheusRule для сервисов Bookshop

**Проверка:**
```bash
# Pods мониторинга
kubectl get pods -n monitoring
```

**Доступ через Ingress:**
```bash
# Добавить в /etc/hosts
# Для Colima (VZ driver) порты пробрасываются на localhost:
echo "127.0.0.1  bookshop.local grafana.bookshop.local prometheus.bookshop.local alertmanager.bookshop.local" | sudo tee -a /etc/hosts
```

| Компонент    | URL                                | Credentials  |
|--------------|------------------------------------|-------------|
| Bookshop     | http://bookshop.local              | —           |
| Grafana      | http://grafana.bookshop.local      | admin/admin |
| Prometheus   | http://prometheus.bookshop.local   | —           |
| Alertmanager | http://alertmanager.bookshop.local | —           |

**Или через port-forward** (без Ingress):
```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring
```

### Шаг 5. OTel-инструментация: разбор кода

Изучите OpenTelemetry-инструментацию в коде приложения:

```bash
# Откройте файл и найдите блок "OpenTelemetry"
cat services/catalog-api/app.py
```

**Ключевые элементы (~20 строк кода = полный distributed tracing):**

```python
# 1. Resource — идентификация сервиса
resource = Resource.create({"service.name": SERVICE_NAME})

# 2. TracerProvider — SDK-реализация
provider = TracerProvider(resource=resource)

# 3. Exporter — отправка в Tempo по gRPC
exporter = OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)
provider.add_span_processor(BatchSpanProcessor(exporter))

# 4. Auto-instrumentation — спаны для HTTP и SQL без изменения бизнес-логики
FlaskInstrumentor().instrument_app(app)    # HTTP spans
Psycopg2Instrumentor().instrument()         # SQL spans
```

**Зависимости** (services/catalog-api/requirements.txt):
```
opentelemetry-api==1.27.0
opentelemetry-sdk==1.27.0
opentelemetry-exporter-otlp-proto-grpc==1.27.0
opentelemetry-instrumentation-flask==0.48b0
opentelemetry-instrumentation-psycopg2==0.48b0
```

### Шаг 6. Конфигурация деплоя

Изучите, как приложение подключается к Tempo:

```bash
# Env var OTEL_EXPORTER_OTLP_ENDPOINT в Deployment
grep -A2 OTEL manifests/04-catalog-api.yaml

# Tempo values: receivers, metrics generator
cat helm-values/tempo.yaml

# Tempo datasource в Grafana: tracesToMetrics, serviceMap
cat manifests/22-grafana-tempo-datasource.yaml
```

**Поток данных:**
```
App (OTel SDK) → OTLP gRPC → tempo.monitoring:4317 → Storage
                                                    → Metrics Generator → Prometheus
                                                    → Grafana (Explore / Service Graph)
```

**Graceful degradation:** если `OTEL_EXPORTER_OTLP_ENDPOINT` пуст — трейсы не отправляются, приложение работает без ошибок.

### Шаг 7. Генерация трафика и исследование трейсов

```bash
bash scripts/05-generate-traffic.sh
```

**Что происходит:**
1. Port-forward к catalog-api (:8081) и order-api (:8082)
2. Генерация трафика: GET /books, GET /books/search, POST /orders
3. Отображение метрик Prometheus
4. Инструкции для исследования трейсов в Grafana

**Исследование трейсов в Grafana:**
1. Grafana → **Explore** → выберите datasource **Tempo**
2. **Search** → Service Name: `catalog-api`
3. Откройте trace → **span tree**: Flask HTTP handler → psycopg2 SELECT
4. Изучите атрибуты: `http.method`, `http.url`, `db.statement`, `db.system`

**Примеры TraceQL-запросов (Grafana → Explore → Tempo):**
```
# Все запросы order-api
{ resource.service.name = "order-api" }

# Медленные запросы (> 500ms)
{ resource.service.name = "catalog-api" && duration > 500ms }

# Ошибки (5xx)
{ resource.service.name = "order-api" && span.http.status_code >= 500 }

# Медленные SQL-запросы
{ span.db.system = "postgresql" && duration > 100ms }
```

**Примеры LogQL-запросов (Grafana → Explore → Loki):**
```
# Все логи catalog-api
{app="catalog-api"}

# Только ошибки order-api
{app="order-api"} | json | level="ERROR"

# Логи с трейсами (кликните TraceID → откроется Tempo)
{app="catalog-api"} | json | traceID != ""
```

**Service Graph:**
Grafana → Explore → Tempo → **Service Graph** — автоматическая карта вызовов между сервисами.

### Шаг 8. Корреляция: от SLO alert → trace → root cause

**SRE Workflow при инциденте:**

```
1. Alert: OrderApiHighBurnRate — burn rate 14.4x
          ↓
2. Dashboard: рост p99 latency order-api
          ↓
3. Explore → Tempo: трейсы order-api с duration > 2s
          ↓
4. Trace: 95% времени — SQL INSERT (full table scan)
          ↓
5. Root Cause: отсутствующий индекс → CREATE INDEX
          ↓
6. Verify: SLO восстановлен, burn rate → норма
```

**Корреляция сигналов:**
| Связь | Как работает |
|-------|-------------|
| Metrics → Traces | Из дашборда переходим к трейсам за период аномалии |
| Traces → Metrics | Tempo Metrics Generator создаёт `service_graph_request_total` в Prometheus |
| Traces → Logs | Tempo → Loki через TraceID (настроено в datasource) |

---

## Домашнее задание (Лекция 2)

1. **Кастомные span attributes:** добавить `book.id`, `order.id`, `customer.name` к существующим трейсам
   ```python
   span = trace.get_current_span()
   span.set_attribute("book.id", book_id)
   ```
2. **Grafana dashboard:** создать дашборд с панелями: SLO gauge, request rate, latency heatmap, trace search panel
3. **TraceQL:** написать запросы для поиска медленных SQL-запросов

---

## Очистка

```bash
bash scripts/99-cleanup.sh

# Удаление стека мониторинга (при необходимости)
helm uninstall tempo -n monitoring
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring

# Удаление Ingress Controller
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx
```
