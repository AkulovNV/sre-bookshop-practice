#!/bin/bash
# =============================================================================
# Шаг 3. Проверка SLI/SLO — smoke-тест через Ingress и метрики
# =============================================================================

set -euo pipefail

NS="bookshop"
NS_INGRESS="ingress-nginx"
BASE_URL="http://bookshop.local"
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Шаг 3: Проверка SLI/SLO                        ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# ---------------------------------------------------------------------------
# Определяем External IP и настраиваем curl --resolve
# ---------------------------------------------------------------------------
EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ${NS_INGRESS} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
CURL_RESOLVE=""

if [[ -n "$EXTERNAL_IP" ]]; then
  CURL_RESOLVE="--resolve bookshop.local:80:${EXTERNAL_IP}"
  echo -e "${GREEN}✓ Ingress External IP: ${EXTERNAL_IP}${NC}"
else
  echo -e "${YELLOW}⚠ Ingress не найден — используем kubectl exec для проверок${NC}"
fi
echo ""

# ---------------------------------------------------------------------------
# 3.1 Проверяем probes каждого сервиса
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 3.1 Проверка Health Endpoints${NC}"
echo ""

for SVC in catalog-api order-api; do
    POD=$(kubectl get pod -n ${NS} -l app.kubernetes.io/name=${SVC} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$POD" ]; then
        echo -e "${RED}  ✗ ${SVC}: pod не найден${NC}"
        continue
    fi

    echo -e "${GREEN}  [${SVC}] Pod: ${POD}${NC}"

    # Liveness
    HEALTH=$(kubectl exec -n ${NS} ${POD} -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/healthz 2>/dev/null || echo "000")
    if [ "$HEALTH" = "200" ]; then
        echo -e "    /healthz (liveness):  ${GREEN}✓ 200 OK${NC}"
    else
        echo -e "    /healthz (liveness):  ${RED}✗ ${HEALTH}${NC}"
    fi

    # Readiness
    READY=$(kubectl exec -n ${NS} ${POD} -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/ready 2>/dev/null || echo "000")
    if [ "$READY" = "200" ]; then
        echo -e "    /ready (readiness):   ${GREEN}✓ 200 OK${NC}"
    else
        echo -e "    /ready (readiness):   ${RED}✗ ${READY}${NC}"
    fi

    # Metrics
    METRICS=$(kubectl exec -n ${NS} ${POD} -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/metrics 2>/dev/null || echo "000")
    if [ "$METRICS" = "200" ]; then
        echo -e "    /metrics (prometheus): ${GREEN}✓ 200 OK${NC}"
    else
        echo -e "    /metrics (prometheus): ${RED}✗ ${METRICS}${NC}"
    fi
    echo ""
done

# ---------------------------------------------------------------------------
# 3.2 Smoke-тест через Ingress
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 3.2 Smoke-тест: генерация трафика через Ingress${NC}"
echo ""

if [[ -n "$CURL_RESOLVE" ]]; then
    echo "  Отправляем 20 запросов к catalog-api (${BASE_URL}/api/books)..."
    SUCCESS=0
    FAIL=0
    TOTAL_TIME=0
    for i in $(seq 1 20); do
        RESULT=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" ${CURL_RESOLVE} "${BASE_URL}/api/books" 2>/dev/null || echo "000 0")
        CODE=$(echo $RESULT | awk '{print $1}')
        TIME=$(echo $RESULT | awk '{print $2}')
        if [ "$CODE" = "200" ]; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAIL=$((FAIL + 1))
        fi
        TOTAL_TIME=$(echo "$TOTAL_TIME + $TIME" | bc 2>/dev/null || echo "0")
    done
    AVG_TIME=$(echo "scale=3; $TOTAL_TIME / 20" | bc 2>/dev/null || echo "N/A")
    AVAILABILITY=$(echo "scale=2; $SUCCESS * 100 / 20" | bc 2>/dev/null || echo "N/A")
    echo -e "  ${GREEN}catalog-api: ${SUCCESS}/20 успешных (${AVAILABILITY}%), avg latency: ${AVG_TIME}s${NC}"
    echo ""

    echo "  Отправляем 20 запросов к order-api (${BASE_URL}/api/orders)..."
    SUCCESS=0
    for i in $(seq 1 20); do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_RESOLVE} "${BASE_URL}/api/orders" 2>/dev/null || echo "000")
        if [ "$CODE" = "200" ]; then
            SUCCESS=$((SUCCESS + 1))
        fi
    done
    AVAILABILITY=$(echo "scale=2; $SUCCESS * 100 / 20" | bc 2>/dev/null || echo "N/A")
    echo -e "  ${GREEN}order-api: ${SUCCESS}/20 успешных (${AVAILABILITY}%)${NC}"
    echo ""
else
    echo -e "${YELLOW}  Пропускаем (Ingress недоступен)${NC}"
    echo ""
fi

# ---------------------------------------------------------------------------
# 3.3 Проверка Prometheus метрик
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 3.3 Prometheus метрики (пример вывода)${NC}"
echo ""

CATALOG_POD=$(kubectl get pod -n ${NS} -l app.kubernetes.io/name=catalog-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$CATALOG_POD" ]; then
    echo -e "${YELLOW}  catalog-api — ключевые SLI метрики:${NC}"
    kubectl exec -n ${NS} ${CATALOG_POD} -- curl -s http://localhost:8080/metrics 2>/dev/null | \
        grep -E "^(http_requests_total|http_request_duration_seconds|db_)" | head -20 || echo "  (метрики недоступны)"
    echo ""
fi

# ---------------------------------------------------------------------------
# 3.4 SLO-шаблон
# ---------------------------------------------------------------------------
echo -e "${BOLD}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   SLO-шаблон Bookshop                                                    ║${NC}"
echo -e "${BOLD}╠══════════════╦═══════════════════╦══════════════════╦════════╦════════════╣${NC}"
echo -e "${BOLD}║ Сервис       ║ CUJ               ║ SLI              ║ SLO    ║ Err Budget ║${NC}"
echo -e "${BOLD}╠══════════════╬═══════════════════╬══════════════════╬════════╬════════════╣${NC}"
echo -e "║ frontend     ║ Открытие каталога ║ Avail: 2xx/total ║ 99.9%  ║ 43.2 мин   ║"
echo -e "║ catalog-api  ║ Поиск книги      ║ Latency p95<300ms║ 99.5%  ║ 3.6 часа   ║"
echo -e "║ order-api    ║ Создание заказа   ║ Avail: 2xx/total ║ 99.95% ║ 21.6 мин   ║"
echo -e "║ postgres     ║ Чтение/запись     ║ Query p99 <50ms  ║ 99.99% ║ 4.3 мин    ║"
echo -e "${BOLD}╚══════════════╩═══════════════════╩══════════════════╩════════╩════════════╝${NC}"
echo ""

echo -e "${CYAN}▶ Проверка SLO-аннотаций в Deployments:${NC}"
for DEPLOY in frontend catalog-api order-api; do
    SLO_TARGET=$(kubectl get deploy ${DEPLOY} -n ${NS} -o jsonpath='{.metadata.annotations.slo\.bookshop/target}' 2>/dev/null || echo "N/A")
    SLO_TYPE=$(kubectl get deploy ${DEPLOY} -n ${NS} -o jsonpath='{.metadata.annotations.slo\.bookshop/type}' 2>/dev/null || echo "N/A")
    echo -e "  ${DEPLOY}: SLO ${SLO_TARGET}% (${SLO_TYPE})"
done
echo ""

echo -e "${CYAN}▶ Дашборды Grafana:${NC}"
echo "  http://grafana.bookshop.local → Bookshop — SLO Overview"
echo "  http://grafana.bookshop.local → Bookshop — API Services"
echo ""

echo -e "${GREEN}✓ Шаг 3 завершён. Обсудите результаты с аудиторией.${NC}"
