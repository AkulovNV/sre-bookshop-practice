#!/bin/bash
# =============================================================================
# Шаг 2. Деплой приложения Bookshop
# Последовательный деплой с проверкой каждого компонента
# =============================================================================

set -euo pipefail

NS="bookshop"
MANIFEST_DIR="$(dirname "$0")/../manifests"
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Шаг 2: Деплой Bookshop                         ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# ---------------------------------------------------------------------------
# 2.1 Создание namespace
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2.1 Создание namespace и ResourceQuota${NC}"
kubectl apply -f ${MANIFEST_DIR}/00-namespace.yaml
echo -e "${GREEN}✓ Namespace '${NS}' создан${NC}"
echo ""

# ---------------------------------------------------------------------------
# 2.2 Секреты
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2.2 Создание секретов${NC}"
kubectl apply -f ${MANIFEST_DIR}/01-postgres-secret.yaml
echo -e "${GREEN}✓ Секреты созданы${NC}"
echo ""

# ---------------------------------------------------------------------------
# 2.3 PostgreSQL
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2.3 Деплой PostgreSQL (StatefulSet)${NC}"
kubectl apply -f ${MANIFEST_DIR}/02-postgres.yaml
echo "Ожидание готовности PostgreSQL..."
kubectl rollout status statefulset/postgres -n ${NS} --timeout=180s
echo -e "${GREEN}✓ PostgreSQL готов${NC}"
echo ""

# Проверяем probes
echo -e "${YELLOW}  Проверка readiness probe:${NC}"
kubectl exec -n ${NS} postgres-0 -- pg_isready -U bookshop -d bookshop && \
  echo -e "${GREEN}  ✓ PostgreSQL принимает соединения${NC}" || \
  echo -e "${RED}  ✗ PostgreSQL не готов${NC}"
echo ""

# ---------------------------------------------------------------------------
# 2.4 catalog-api
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2.4 Деплой catalog-api${NC}"
kubectl apply -f ${MANIFEST_DIR}/03-catalog-api-config.yaml
kubectl apply -f ${MANIFEST_DIR}/04-catalog-api.yaml
echo "Ожидание готовности catalog-api..."
kubectl rollout status deploy/catalog-api -n ${NS} --timeout=300s
echo -e "${GREEN}✓ catalog-api готов${NC}"
echo ""

# ---------------------------------------------------------------------------
# 2.5 order-api
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2.5 Деплой order-api${NC}"
kubectl apply -f ${MANIFEST_DIR}/05-order-api-config.yaml
kubectl apply -f ${MANIFEST_DIR}/06-order-api.yaml
echo "Ожидание готовности order-api..."
kubectl rollout status deploy/order-api -n ${NS} --timeout=300s
echo -e "${GREEN}✓ order-api готов${NC}"
echo ""

# ---------------------------------------------------------------------------
# 2.6 Frontend
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2.6 Деплой frontend${NC}"
kubectl apply -f ${MANIFEST_DIR}/07-frontend-config.yaml
kubectl apply -f ${MANIFEST_DIR}/08-frontend.yaml
echo "Ожидание готовности frontend..."
kubectl rollout status deploy/frontend -n ${NS} --timeout=120s
echo -e "${GREEN}✓ Frontend готов${NC}"
echo ""

# ---------------------------------------------------------------------------
# 2.7 Ingress и NetworkPolicies
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2.7 Настройка Ingress и NetworkPolicy${NC}"
kubectl apply -f ${MANIFEST_DIR}/09-ingress.yaml
kubectl apply -f ${MANIFEST_DIR}/10-network-policies.yaml
echo -e "${GREEN}✓ Ingress и NetworkPolicy применены${NC}"
echo ""

# ---------------------------------------------------------------------------
# 2.8 Мониторинг (опционально)
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2.8 Мониторинг (ServiceMonitor + PrometheusRule)${NC}"
if kubectl api-resources | grep -q servicemonitors 2>/dev/null; then
  kubectl apply -f ${MANIFEST_DIR}/11-monitoring.yaml
  echo -e "${GREEN}✓ ServiceMonitor и PrometheusRule созданы${NC}"
else
  echo -e "${YELLOW}⚠ Prometheus Operator не обнаружен — мониторинг-манифесты пропущены${NC}"
  echo "  Для установки: helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack"
fi
echo ""

# ---------------------------------------------------------------------------
# Итоговая проверка
# ---------------------------------------------------------------------------
echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Итоговый статус                                 ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Pods:${NC}"
kubectl get pods -n ${NS} -o wide
echo ""
echo -e "${CYAN}Services:${NC}"
kubectl get svc -n ${NS}
echo ""
echo -e "${CYAN}HPA:${NC}"
kubectl get hpa -n ${NS}
echo ""
echo -e "${CYAN}PDB:${NC}"
kubectl get pdb -n ${NS}
echo ""

# ---------------------------------------------------------------------------
# Доступ
# ---------------------------------------------------------------------------
echo -e "${BOLD}▶ Доступ к приложению:${NC}"
echo ""
echo "  # Port-forward (быстрый доступ):"
echo "  kubectl port-forward svc/frontend 8080:80 -n ${NS}"
echo "  # Затем откройте: http://localhost:8080"
echo ""
echo "  # Проверка API:"
echo "  kubectl port-forward svc/catalog-api 8081:8080 -n ${NS}"
echo "  curl http://localhost:8081/books"
echo "  curl http://localhost:8081/books/search?q=SRE"
echo ""
echo "  # Проверка health:"
echo "  curl http://localhost:8081/healthz"
echo "  curl http://localhost:8081/ready"
echo "  curl http://localhost:8081/metrics"
