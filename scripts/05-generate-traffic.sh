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

# Colima с VZ driver не маршрутизирует IP VM на хост — используем localhost
if [[ -z "$EXTERNAL_IP" ]] || ! curl -sf --connect-timeout 2 -H 'Host: bookshop.local' "http://${EXTERNAL_IP}/" > /dev/null 2>&1; then
  EXTERNAL_IP="127.0.0.1"
fi

echo "  Ingress IP: ${EXTERNAL_IP}"
echo "  Проверяем доступность bookshop.local..."

# Используем --resolve для обхода DNS (если /etc/hosts не настроен)
CURL_RESOLVE="--resolve bookshop.local:80:${EXTERNAL_IP}"

REACHABLE=false
for attempt in 1 2 3; do
  if curl -sf --connect-timeout 3 ${CURL_RESOLVE} ${BASE_URL}/api/books > /dev/null 2>&1; then
    REACHABLE=true
    break
  fi
  sleep 1
done
if $REACHABLE; then
  echo -e "${GREEN}✓ Bookshop API доступен через Ingress${NC}"
else
  echo -e "${YELLOW}⚠ bookshop.local недоступен — проверьте Ingress Controller${NC}"
  echo "  Попробуйте: kubectl get pods -n ingress-nginx"
  exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# 5.3 Генерация трафика — catalog-api
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 5.3 Генерация трафика на catalog-api${NC}"

# Вспомогательная функция: отправить N запросов, подсчитать результаты
send_requests() {
  local URL="$1" COUNT="$2" LABEL="$3"
  local OK=0 ERRORS=0
  for i in $(seq 1 ${COUNT}); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${URL}")
    if [[ "$STATUS" =~ ^2 ]]; then ((OK++)); else ((ERRORS++)); fi
  done
  if [[ "$ERRORS" -gt 0 ]]; then
    echo -e "    ${YELLOW}${LABEL}: ${OK} ok, ${ERRORS} errors (из ${COUNT})${NC}"
  else
    echo -e "    ${GREEN}✓ ${LABEL}: ${OK}/${COUNT} ok${NC}"
  fi
}

echo "  → GET /api/books (100 запросов)..."
send_requests "${BASE_URL}/api/books" 100 "/api/books"

echo "  → GET /api/books/<id> (книги 1-8, по 5 раз = 40)..."
OK=0; ERRORS=0
for book_id in $(seq 1 8); do
  for _ in $(seq 1 5); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${BASE_URL}/api/books/${book_id}")
    if [[ "$STATUS" =~ ^2 ]]; then ((OK++)); else ((ERRORS++)); fi
  done
done
if [[ "$ERRORS" -gt 0 ]]; then
  echo -e "    ${YELLOW}/api/books/<id>: ${OK} ok, ${ERRORS} errors (из 40)${NC}"
else
  echo -e "    ${GREEN}✓ /api/books/<id>: ${OK}/40 ok${NC}"
fi

echo "  → GET /api/books/search (20 запросов)..."
send_requests "${BASE_URL}/api/books/search?q=SRE" 10 "/api/books/search?q=SRE"
send_requests "${BASE_URL}/api/books/search?q=Google" 10 "/api/books/search?q=Google"
echo ""

# ---------------------------------------------------------------------------
# 5.4 Генерация трафика — order-api
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 5.4 Генерация трафика на order-api${NC}"

echo "  → GET /api/orders (60 запросов)..."
send_requests "${BASE_URL}/api/orders" 60 "/api/orders"

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

echo "  → GET /api/orders/<id> (детали заказов)..."
for order_id in $(seq 1 ${CREATED}); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${BASE_URL}/api/orders/${order_id}")
  echo -e "    Заказ #${order_id}: HTTP ${STATUS}"
done
echo ""

# ---------------------------------------------------------------------------
# 5.5 Burst-трафик — нагрузка для проявления error rate
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 5.5 Burst-трафик (параллельные запросы)${NC}"
echo "  Отправляем 100 запросов параллельно (10 пачек по 10)..."
BURST_OK=0; BURST_ERR=0
for batch in $(seq 1 10); do
  PIDS=""
  TMPDIR=$(mktemp -d)
  for j in $(seq 1 10); do
    (
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${BASE_URL}/api/books")
      echo "$STATUS" > "${TMPDIR}/${j}"
    ) &
    PIDS="$PIDS $!"
  done
  wait $PIDS 2>/dev/null
  for f in "${TMPDIR}"/*; do
    S=$(cat "$f")
    if [[ "$S" =~ ^2 ]]; then ((BURST_OK++)); else ((BURST_ERR++)); fi
  done
  rm -rf "$TMPDIR"
done
echo -e "    ${YELLOW}Burst: ${BURST_OK} ok, ${BURST_ERR} errors (из 100)${NC}"
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
echo -e "${CYAN}▶ Трейсы (Tempo — Grafana → Explore → Tempo):${NC}"
echo ""
echo "  1. Search → Service Name: catalog-api или order-api"
echo "  2. Откройте trace → увидите span tree:"
echo "     Flask HTTP handler → psycopg2 SELECT/INSERT"
echo ""
echo "  Примеры TraceQL-запросов (datasource: Tempo):"
echo '    { resource.service.name = "order-api" }'
echo '    { resource.service.name = "catalog-api" && duration > 500ms }'
echo '    { resource.service.name = "order-api" && span.http.status_code >= 500 }'
echo ""
echo -e "${CYAN}▶ Логи (Loki — Grafana → Explore → Loki):${NC}"
echo ""
echo "  Примеры LogQL-запросов (datasource: Loki):"
echo '    {app="catalog-api"}'
echo '    {app="order-api"} | json | level="ERROR"'
echo '    {app="catalog-api"} | json | traceID != ""'
echo ""
echo "  Кликните на TraceID в строке лога → откроется trace в Tempo"
echo ""
echo -e "${CYAN}▶ SRE Workflow:${NC}"
echo "  Alert (burn rate) → Dashboard (p99 рост) → Trace (медленный span) → Logs (детали) → Root Cause"
