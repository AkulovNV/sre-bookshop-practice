# Практика: Приложение «Bookshop»

## Архитектура

```
                    ┌─────────────┐
                    │   Ingress   │
                    │  /bookshop  │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │   frontend  │
                    │  (nginx)    │
                    │  Port: 80   │
                    └───┬─────┬───┘
                        │     │
              ┌─────────▼┐   ┌▼──────────┐
              │catalog-api│   │ order-api  │
              │ (Python)  │   │ (Python)   │
              │ Port: 8080│   │ Port: 8080 │
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
| catalog-api  | Deployment   | python:3.12-slim (+ app code)  | 8080 |
| order-api    | Deployment   | python:3.12-slim (+ app code)  | 8080 |
| postgres     | StatefulSet  | postgres:16-alpine             | 5432 |

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

## Структура манифестов

```
manifests/
├── 00-namespace.yaml          # Namespace + ResourceQuota
├── 01-postgres-secret.yaml    # Credentials для PostgreSQL
├── 02-postgres.yaml           # StatefulSet + Service + PDB
├── 03-catalog-api-config.yaml # ConfigMap с кодом приложения
├── 04-catalog-api.yaml        # Deployment + Service + HPA + PDB
├── 05-order-api-config.yaml   # ConfigMap с кодом приложения
├── 06-order-api.yaml          # Deployment + Service + HPA + PDB
├── 07-frontend-config.yaml    # ConfigMap (nginx.conf + index.html)
├── 08-frontend.yaml           # Deployment + Service + HPA + PDB
├── 09-ingress.yaml            # Ingress для внешнего доступа
├── 10-network-policies.yaml   # NetworkPolicy для изоляции
└── 11-monitoring.yaml         # ServiceMonitor / PrometheusRule (SLO)
```

## Сценарий практики (15 мин)

### Шаг 1. Картография (3 мин)
```bash
# Запустить скрипт инвентаризации
bash scripts/01-cartography.sh
```

### Шаг 2. Деплой (5 мин)
```bash
# Запустить деплой и проверку
bash scripts/02-deploy.sh
```

### Шаг 3. Определение SLO (5 мин)
```bash
# Посмотреть SLO-шаблон и Prometheus rules
cat docs/slo-template.md
cat manifests/11-monitoring.yaml
```

### Шаг 4. Обсуждение (2 мин)
Открытые вопросы — см. `docs/discussion-questions.md`
