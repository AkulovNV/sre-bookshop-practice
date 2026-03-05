#!/bin/bash
# =============================================================================
# Шаг 1. Картография системы Bookshop
# Скрипт для демонстрации инвентаризации и маппинга зависимостей
# =============================================================================

set -euo pipefail

NS="bookshop"
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Шаг 1: Картография системы Bookshop             ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# ---------------------------------------------------------------------------
# 1.1 Инвентаризация: какие ресурсы есть в namespace?
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 1.1 Инвентаризация ресурсов в namespace '${NS}'${NC}"
echo -e "${YELLOW}Команда: kubectl get all -n ${NS}${NC}"
echo "---"
kubectl get all -n ${NS} 2>/dev/null || echo "(namespace ещё не создан — будет создан на шаге 2)"
echo ""

# ---------------------------------------------------------------------------
# 1.2 Deployments и их labels
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 1.2 Deployments и их метки${NC}"
echo -e "${YELLOW}Команда: kubectl get deploy -n ${NS} --show-labels${NC}"
echo "---"
kubectl get deploy -n ${NS} --show-labels 2>/dev/null || echo "(нет deployments)"
echo ""

# ---------------------------------------------------------------------------
# 1.3 Services и их endpoints
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 1.3 Services — точки взаимодействия${NC}"
echo -e "${YELLOW}Команда: kubectl get svc -n ${NS} -o wide${NC}"
echo "---"
kubectl get svc -n ${NS} -o wide 2>/dev/null || echo "(нет services)"
echo ""

# ---------------------------------------------------------------------------
# 1.4 Маппинг зависимостей через env variables
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 1.4 Маппинг зависимостей (env variables)${NC}"
echo "Ищем переменные окружения с URL зависимых сервисов..."
echo "---"

for DEPLOY in catalog-api order-api frontend; do
    echo -e "${GREEN}[$DEPLOY]${NC}"
    kubectl get deploy ${DEPLOY} -n ${NS} -o jsonpath='{range .spec.template.spec.containers[*]}{.name}:{"\n"}{range .env[*]}  {.name}={.value}{"\n"}{end}{range .envFrom[*]}  envFrom: {.secretRef.name}{"\n"}{end}{end}' 2>/dev/null || echo "  (не найден)"
    echo ""
done

# ---------------------------------------------------------------------------
# 1.5 Ingress — точка входа
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 1.5 Ingress — внешняя точка входа${NC}"
echo -e "${YELLOW}Команда: kubectl get ingress -n ${NS}${NC}"
echo "---"
kubectl get ingress -n ${NS} 2>/dev/null || echo "(нет ingress)"
echo ""

# ---------------------------------------------------------------------------
# 1.6 Persistent storage
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 1.6 Persistent Volumes — данные${NC}"
echo -e "${YELLOW}Команда: kubectl get pvc -n ${NS}${NC}"
echo "---"
kubectl get pvc -n ${NS} 2>/dev/null || echo "(нет PVC)"
echo ""

# ---------------------------------------------------------------------------
# 1.7 Network Policies
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 1.7 Network Policies — правила доступа${NC}"
echo -e "${YELLOW}Команда: kubectl get netpol -n ${NS}${NC}"
echo "---"
kubectl get netpol -n ${NS} 2>/dev/null || echo "(нет network policies)"
echo ""

# ---------------------------------------------------------------------------
# Итог: карта зависимостей
# ---------------------------------------------------------------------------
echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Карта зависимостей Bookshop                     ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  ┌──────────────┐"
echo "  │   Ingress    │ ← bookshop.local"
echo "  └──────┬───────┘"
echo "         │ :80"
echo "  ┌──────▼───────┐"
echo "  │   frontend   │ nginx (proxy)"
echo "  └──┬────────┬──┘"
echo "     │        │"
echo "     │ :8080  │ :8080"
echo "     ▼        ▼"
echo "  ┌────────┐ ┌──────────┐"
echo "  │catalog │ │ order    │"
echo "  │  -api  │ │  -api    │"
echo "  └───┬────┘ └────┬─────┘"
echo "      │            │"
echo "      │ :5432      │ :5432"
echo "      ▼            ▼"
echo "  ┌──────────────────┐"
echo "  │    PostgreSQL     │ (StatefulSet)"
echo "  │   bookshop DB    │"
echo "  └──────────────────┘"
echo ""
echo -e "${GREEN}Компоненты: 4 (frontend, catalog-api, order-api, postgres)${NC}"
echo -e "${GREEN}Синхронные зависимости: HTTP (frontend→api→db)${NC}"
echo -e "${GREEN}Внешние зависимости: нет (self-contained demo)${NC}"
echo -e "${GREEN}SPOF: PostgreSQL (single replica)${NC}"
