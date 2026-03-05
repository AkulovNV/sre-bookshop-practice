# SLO-документ: Bookshop

## Общие сведения

| Поле | Значение |
|------|----------|
| **Система** | Bookshop — интернет-магазин книг |
| **Владелец** | SRE Team |
| **Дата создания** | _(текущая дата)_ |
| **Окно наблюдения** | 30 дней (rolling) |
| **Ревизия** | 1.0 |

---

## 1. Frontend (nginx)

### Critical User Journey
Пользователь открывает главную страницу каталога книг.

### SLI
| Тип | Метрика | Источник |
|-----|---------|----------|
| Availability | `successful_requests / total_requests * 100%` | nginx access.log / Ingress metrics |
| Latency | `requests_faster_than_200ms / total * 100%` | nginx `$request_time` |

### SLO

| SLI | Порог | SLO Target | Error Budget (30 дн.) |
|-----|-------|------------|----------------------|
| Availability | HTTP 2xx | **99.9%** | 43.2 мин |
| Latency p99 | < 200ms | **99.0%** | 432 мин |

### Prometheus запрос (Availability)
```promql
sum(rate(nginx_http_requests_total{namespace="bookshop", status!~"5.."}[5m]))
/
sum(rate(nginx_http_requests_total{namespace="bookshop"}[5m]))
* 100
```

### Политика при исчерпании бюджета
- **> 50%**: нормальный режим, фичи и рефакторинг
- **20–50%**: приоритизировать задачи frontend-надёжности
- **< 20%**: заморозка фич, фокус на стабильности
- **= 0%**: полная заморозка, только hotfixes

---

## 2. Catalog API (Python/Flask)

### Critical User Journey
Пользователь ищет книгу по названию или автору и просматривает результаты.

### SLI
| Тип | Метрика | Источник |
|-----|---------|----------|
| Latency | `requests_below_300ms / total_requests * 100%` | Application Prometheus metrics |
| Availability | `non_5xx_requests / total_requests * 100%` | Application Prometheus metrics |

### SLO

| SLI | Порог | SLO Target | Error Budget (30 дн.) |
|-----|-------|------------|----------------------|
| Latency p95 | < 300ms | **99.5%** | 3.6 часа |
| Availability | HTTP non-5xx | **99.5%** | 3.6 часа |

### Prometheus запрос (Latency SLI)
```promql
sum(rate(http_request_duration_seconds_bucket{
  namespace="bookshop",
  job="catalog-api",
  le="0.3"
}[5m]))
/
sum(rate(http_request_duration_seconds_count{
  namespace="bookshop",
  job="catalog-api"
}[5m]))
* 100
```

### Обоснование
Поиск — не критичная финансовая операция, поэтому SLO менее строгий, чем у order-api. Пользователь толерантен к задержке поиска до 300ms. Бюджет 3.6 часа позволяет деплоить чаще.

---

## 3. Order API (Python/Flask)

### Critical User Journey
Пользователь оформляет заказ и ожидает подтверждения.

### SLI
| Тип | Метрика | Источник |
|-----|---------|----------|
| Availability | `non_5xx_requests / total_requests * 100%` | Application Prometheus metrics |
| Latency | `requests_below_500ms / total_requests * 100%` | Application Prometheus metrics |

### SLO

| SLI | Порог | SLO Target | Error Budget (30 дн.) |
|-----|-------|------------|----------------------|
| Availability | HTTP non-5xx | **99.95%** | 21.6 мин |
| Latency p95 | < 500ms | **99.9%** | 43.2 мин |

### Prometheus запрос (Availability SLI)
```promql
sum(rate(http_requests_total{
  namespace="bookshop",
  job="order-api",
  status!~"5.."
}[5m]))
/
sum(rate(http_requests_total{
  namespace="bookshop",
  job="order-api"
}[5m]))
* 100
```

### Обоснование
Order API обрабатывает финансовые операции. Потеря заказа = потеря дохода и доверия. SLO строже (99.95% vs 99.5%), больше реплик (3 vs 2), строже PDB (minAvailable: 2).

---

## 4. PostgreSQL

### Critical User Journey
Все операции чтения/записи данных (каталог + заказы).

### SLI
| Тип | Метрика | Источник |
|-----|---------|----------|
| Availability | `successful_connections / total_attempts * 100%` | pg_exporter / application metrics |
| Latency | `queries_below_50ms / total_queries * 100%` | `db_query_duration_seconds` |

### SLO

| SLI | Порог | SLO Target | Error Budget (30 дн.) |
|-----|-------|------------|----------------------|
| Availability | `pg_isready` success | **99.99%** | 4.3 мин |
| Latency p99 | < 50ms | **99.9%** | 43.2 мин |

### Обоснование
БД — единая точка отказа (SPOF). Недоступность БД = недоступность всей системы. Самый строгий SLO. В production: HA PostgreSQL (Patroni), read replicas, connection pooling (PgBouncer).

---

## Общая таблица SLO

| Сервис | CUJ | SLI | SLO | Error Budget | Criticality |
|--------|-----|-----|-----|-------------|-------------|
| frontend | Открытие каталога | Availability 2xx | 99.9% | 43.2 мин | Medium |
| catalog-api | Поиск книги | Latency p95 <300ms | 99.5% | 3.6 часа | Low |
| order-api | Оформление заказа | Availability non-5xx | 99.95% | 21.6 мин | **High** |
| postgres | Чтение/запись | Availability pg_isready | 99.99% | 4.3 мин | **Critical** |

---

## Burn Rate Alerts

Используем multi-window burn rate alerts (Google SRE Workbook, Chapter 5):

| Окно | Burn Rate | Бюджет за окно | Severity | Reaction |
|------|-----------|----------------|----------|----------|
| 1h / 5m | 14.4x | 2% | Critical | Немедленно |
| 6h / 30m | 6x | 5% | Warning | В рабочее время |
| 3d / 6h | 1x | 10% | Ticket | Плановая работа |
