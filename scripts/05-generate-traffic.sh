#!/bin/bash
# =============================================================================
# Шаг 5. Генерация трафика и исследование трейсов
# Создаёт нагрузку на Bookshop API через Ingress для появления трейсов в Tempo
# =============================================================================

set -euo pipefail

NS="bookshop"
NS_MONITORING="monitoring"
NS_INGRESS="ingress-nginx"
BASE_URL="http://bookshop.local"
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Шаг 5: Генерация трафика и исследование трейсов ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# ---------------------------------------------------------------------------
# 5.1 Проверка компонентов
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 5.1 Проверка готовности компонентов${NC}"

CATALOG_READY=$(kubectl get deploy catalog-api -n ${NS} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
ORDER_READY=$(kubectl get deploy order-api -n ${NS} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
TEMPO_READY=$(kubectl get pods -n ${NS_MONITORING} -l app.kubernetes.io/name=tempo -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

if [[ "$CATALOG_READY" == "0" || "$ORDER_READY" == "0" ]]; then
  echo -e "${RED}✗ Приложение Bookshop не задеплоено. Сначала выполните:${NC}"
  echo "  bash scripts/02-deploy.sh"
  exit 1
fi

if [[ "$TEMPO_READY" != "Running" ]]; then
  echo -e "${YELLOW}⚠ Tempo не запущен — трейсы не будут собираться${NC}"
fi

echo -e "${GREEN}✓ catalog-api: ${CATALOG_READY} реплик ready${NC}"
echo -e "${GREEN}✓ order-api: ${ORDER_READY} реплик ready${NC}"
echo ""

# ---------------------------------------------------------------------------
# 5.2 Проверка доступности через Ingress
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 5.2 Проверка доступности через Ingress${NC}"

EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ${NS_INGRESS} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -z "$EXTERNAL_IP" ]]; then
  echo -e "${RED}✗ Ingress Controller не найден или External IP не назначен${NC}"
  echo "  Установите: bash scripts/04-install-monitoring.sh"
  exit 1
fi

echo "  External IP: ${EXTERNAL_IP}"
echo "  Проверяем доступность bookshop.local..."

# Используем --resolve для обхода DNS (если /etc/hosts не настроен)
CURL_RESOLVE="--resolve bookshop.local:80:${EXTERNAL_IP}"

if curl -sf ${CURL_RESOLVE} ${BASE_URL}/api/books > /dev/null 2>&1; then
  echo -e "${GREEN}✓ Bookshop API доступен через Ingress${NC}"
else
  echo -e "${YELLOW}⚠ bookshop.local недоступен — проверьте /etc/hosts или Ingress${NC}"
  echo "  Попробуйте: echo '${EXTERNAL_IP}  bookshop.local' | sudo tee -a /etc/hosts"
  exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# 5.3 Генерация трафика — catalog-api
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 5.3 Генерация трафика на catalog-api${NC}"

echo "  → GET /api/books (50 запросов)..."
SUCCESS=0
FAIL=0
for i in $(seq 1 50); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} ${BASE_URL}/api/books)
  if [[ "$STATUS" == "200" ]]; then
    ((SUCCESS++))
  else
    ((FAIL++))
  fi
done
echo -e "    ${GREEN}✓ Успешных: ${SUCCESS}, Ошибок: ${FAIL}${NC}"

echo "  → GET /api/books/<id> (книги 1-8, по 5 раз)..."
SUCCESS=0
FAIL=0
for book_id in $(seq 1 8); do
  for _ in $(seq 1 5); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${BASE_URL}/api/books/${book_id}")
    if [[ "$STATUS" == "200" ]]; then
      ((SUCCESS++))
    else
      ((FAIL++))
    fi
  done
done
echo -e "    ${GREEN}✓ Успешных: ${SUCCESS}, Ошибок: ${FAIL}${NC}"

echo "  → GET /api/books/search?q=SRE (10 запросов)..."
SUCCESS=0
for i in $(seq 1 10); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${BASE_URL}/api/books/search?q=SRE")
  [[ "$STATUS" == "200" ]] && ((SUCCESS++))
done
echo -e "    ${GREEN}✓ Успешных: ${SUCCESS}/10${NC}"

echo "  → GET /api/books/search?q=Google (10 запросов)..."
SUCCESS=0
for i in $(seq 1 10); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${BASE_URL}/api/books/search?q=Google")
  [[ "$STATUS" == "200" ]] && ((SUCCESS++))
done
echo -e "    ${GREEN}✓ Успешных: ${SUCCESS}/10${NC}"
echo ""

# ---------------------------------------------------------------------------
# 5.4 Генерация трафика — order-api
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 5.4 Генерация трафика на order-api${NC}"

echo "  → GET /api/orders (20 запросов)..."
SUCCESS=0
for i in $(seq 1 20); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} ${BASE_URL}/api/orders)
  [[ "$STATUS" == "200" ]] && ((SUCCESS++))
done
echo -e "    ${GREEN}✓ Успешных: ${SUCCESS}/20${NC}"

echo "  → POST /api/orders — создание заказов (5 штук)..."
CREATED=0
for i in $(seq 1 5); do
  RESPONSE=$(curl -s -w "\n%{http_code}" ${CURL_RESOLVE} -X POST "${BASE_URL}/api/orders" \
    -H 'Content-Type: application/json' \
    -d "{\"customer\":\"student-${i}\",\"items\":[{\"book_id\":${i},\"quantity\":1}]}")
  STATUS=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -1)
  if [[ "$STATUS" == "201" ]]; then
    ((CREATED++))
    ORDER_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
    echo -e "    ${GREEN}✓ Заказ #${ORDER_ID} создан (student-${i})${NC}"
  else
    echo -e "    ${YELLOW}⚠ Заказ для student-${i}: HTTP ${STATUS}${NC}"
  fi
done
echo ""

echo "  → GET /api/orders/<id> (запрос деталей созданных заказов)..."
for order_id in $(seq 1 ${CREATED}); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${BASE_URL}/api/orders/${order_id}")
  echo -e "    Заказ #${order_id}: HTTP ${STATUS}"
done
echo ""

# ---------------------------------------------------------------------------
# 5.5 Итоги
# ---------------------------------------------------------------------------
echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Исследование трейсов в Grafana                  ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}▶ Доступ к Grafana:${NC}"
echo "  http://grafana.bookshop.local (admin/admin)"
echo ""
echo -e "${CYAN}▶ Поиск трейсов:${NC}"
echo "  1. Grafana → Explore → выберите datasource Tempo"
echo "  2. Search → Service Name: catalog-api или order-api"
echo "  3. Откройте trace → увидите span tree:"
echo "     Flask HTTP handler → psycopg2 SELECT/INSERT"
echo ""
echo -e "${CYAN}▶ Примеры TraceQL-запросов:${NC}"
echo ""
echo '  # Все запросы order-api'
echo '  { resource.service.name = "order-api" }'
echo ""
echo '  # Медленные запросы (> 500ms)'
echo '  { resource.service.name = "catalog-api" && duration > 500ms }'
echo ""
echo '  # Ошибки (5xx)'
echo '  { resource.service.name = "order-api" && span.http.status_code >= 500 }'
echo ""
echo -e "${CYAN}▶ Логи (Loki):${NC}"
echo "  1. Grafana → Explore → Loki"
echo '  2. {app="catalog-api"} | json | traceID != ""'
echo "  3. Нажмите на TraceID → откроется trace в Tempo"
echo ""
echo -e "${CYAN}▶ SRE Workflow:${NC}"
echo "  Alert (burn rate) → Dashboard (p99 рост) → Trace (медленный span) → Logs (детали) → Root Cause"
