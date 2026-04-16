#!/bin/bash
# =============================================================================
# Шаг 4. Установка стека мониторинга (Observability)
# ingress-nginx + kube-prometheus-stack + Tempo + Loki + Promtail
# =============================================================================

set -euo pipefail

MANIFEST_DIR="$(dirname "$0")/../manifests"
HELM_VALUES_DIR="$(dirname "$0")/../helm-values"
NS_INGRESS="ingress-nginx"
NS_MONITORING="monitoring"
NS_BOOKSHOP="bookshop"
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Шаг 4: Установка стека мониторинга              ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.1 Добавление Helm-репозиториев
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.1 Добавление Helm-репозиториев${NC}"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
echo -e "${GREEN}✓ Helm-репозитории обновлены${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.2 Установка Ingress Controller (ingress-nginx)
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.2 Установка ingress-nginx${NC}"
if kubectl get ingressclass nginx &>/dev/null; then
  echo -e "${GREEN}✓ ingress-nginx уже установлен${NC}"
else
  echo "  Компоненты: Ingress Controller (LoadBalancer)"
  echo ""

  helm upgrade --install ingress-nginx \
    ingress-nginx/ingress-nginx \
    --namespace ${NS_INGRESS} \
    --create-namespace \
    --values ${HELM_VALUES_DIR}/ingress-nginx.yaml \
    --wait \
    --timeout 5m

  echo -e "${GREEN}✓ ingress-nginx установлен${NC}"
fi

# Получаем Ingress IP (fallback на localhost для Colima VZ)
EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ${NS_INGRESS} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [[ -z "$EXTERNAL_IP" ]] || ! curl -sf --connect-timeout 2 -H 'Host: bookshop.local' "http://${EXTERNAL_IP}/" > /dev/null 2>&1; then
  EXTERNAL_IP="127.0.0.1"
fi
echo -e "  Ingress IP: ${BOLD}${EXTERNAL_IP}${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.3 Создание namespace monitoring
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.3 Создание namespace ${NS_MONITORING}${NC}"
kubectl create namespace ${NS_MONITORING} --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace '${NS_MONITORING}' готов${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.4 Установка kube-prometheus-stack
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.4 Установка kube-prometheus-stack${NC}"
echo "  Компоненты: Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics"
echo ""

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace ${NS_MONITORING} \
  --values ${HELM_VALUES_DIR}/kube-prometheus-stack.yaml \
  --wait \
  --timeout 10m

echo -e "${GREEN}✓ kube-prometheus-stack установлен${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.5 Установка Grafana Tempo
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.5 Установка Grafana Tempo${NC}"
echo "  Backend для distributed traces (OTLP gRPC :4317, HTTP :4318)"
echo ""

helm upgrade --install tempo \
  grafana/tempo \
  --namespace ${NS_MONITORING} \
  --values ${HELM_VALUES_DIR}/tempo.yaml \
  --wait \
  --timeout 10m

echo -e "${GREEN}✓ Grafana Tempo установлен${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.6 Установка Grafana Loki (логирование)
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.6 Установка Grafana Loki${NC}"
echo "  Backend для логов (HTTP :3100)"
echo ""

helm upgrade --install loki \
  grafana/loki \
  --namespace ${NS_MONITORING} \
  --values ${HELM_VALUES_DIR}/loki.yaml \
  --wait \
  --timeout 10m

echo -e "${GREEN}✓ Grafana Loki установлен${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.7 Установка Promtail (сбор логов)
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.7 Установка Promtail${NC}"
echo "  DaemonSet — собирает логи со всех подов и отправляет в Loki"
echo ""

helm upgrade --install promtail \
  grafana/promtail \
  --namespace ${NS_MONITORING} \
  --values ${HELM_VALUES_DIR}/promtail.yaml \
  --wait \
  --timeout 5m

echo -e "${GREEN}✓ Promtail установлен${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.8 Настройка datasources в Grafana
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.8 Добавление datasources в Grafana${NC}"
kubectl apply -f ${MANIFEST_DIR}/22-grafana-tempo-datasource.yaml
kubectl apply -f ${MANIFEST_DIR}/24-loki-datasource.yaml
echo -e "${GREEN}✓ Datasources добавлены: Tempo, Loki (через sidecar ConfigMap)${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.9 Загрузка Grafana-дашбордов
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.9 Загрузка Grafana-дашбордов${NC}"
kubectl apply -f ${MANIFEST_DIR}/12-grafana-dashboard.yaml
kubectl apply -f ${MANIFEST_DIR}/13-grafana-slo-dashboard.yaml
echo -e "${GREEN}✓ Dashboards загружены: API Services, SLO Overview${NC}"
echo ""

# ---------------------------------------------------------------------------
# 4.10 Ingress для мониторинга (Grafana, Prometheus, Alertmanager)
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.10 Ingress для мониторинга${NC}"
kubectl apply -f ${MANIFEST_DIR}/23-monitoring-ingress.yaml
echo -e "${GREEN}✓ Ingress создан:${NC}"
echo -e "  grafana.bookshop.local      → Grafana (admin/admin)"
echo -e "  prometheus.bookshop.local    → Prometheus"
echo -e "  alertmanager.bookshop.local  → Alertmanager"
echo ""

# ---------------------------------------------------------------------------
# 4.11 Применение ServiceMonitor + PrometheusRule (если приложение задеплоено)
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4.11 Применение ServiceMonitor и PrometheusRule${NC}"
if kubectl get namespace ${NS_BOOKSHOP} &>/dev/null; then
  kubectl apply -f ${MANIFEST_DIR}/11-monitoring.yaml
  echo -e "${GREEN}✓ ServiceMonitor и PrometheusRule применены${NC}"
else
  echo -e "${YELLOW}⚠ Namespace '${NS_BOOKSHOP}' не найден — мониторинг-манифесты пропущены${NC}"
  echo "  Сначала задеплойте приложение: bash scripts/02-deploy.sh"
fi
echo ""

# ---------------------------------------------------------------------------
# Проверка
# ---------------------------------------------------------------------------
echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Проверка стека                                  ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}Pods в namespace ${NS_MONITORING}:${NC}"
kubectl get pods -n ${NS_MONITORING} --sort-by='.metadata.name'
echo ""

echo -e "${CYAN}Pods в namespace ${NS_INGRESS}:${NC}"
kubectl get pods -n ${NS_INGRESS}
echo ""

echo -e "${CYAN}Ingress:${NC}"
kubectl get ingress --all-namespaces
echo ""

# ---------------------------------------------------------------------------
# Доступ
# ---------------------------------------------------------------------------
EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ${NS_INGRESS} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [[ -z "$EXTERNAL_IP" ]] || ! curl -sf --connect-timeout 2 -H 'Host: bookshop.local' "http://${EXTERNAL_IP}/" > /dev/null 2>&1; then
  EXTERNAL_IP="127.0.0.1"
fi

echo -e "${BOLD}▶ Доступ к компонентам:${NC}"
echo ""
echo "  Ingress IP: ${EXTERNAL_IP}"
echo ""
echo "  Добавьте в /etc/hosts (если ещё не добавлено):"
echo "  ${EXTERNAL_IP}  bookshop.local grafana.bookshop.local prometheus.bookshop.local alertmanager.bookshop.local"
echo ""
echo "  Grafana:      http://grafana.bookshop.local      (admin/admin)"
echo "  Prometheus:   http://prometheus.bookshop.local"
echo "  Alertmanager: http://alertmanager.bookshop.local"
echo "  Bookshop:     http://bookshop.local"
echo ""
echo "  Или через port-forward (без Ingress):"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n ${NS_MONITORING}"
echo "  kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n ${NS_MONITORING}"
echo ""
echo -e "${BOLD}▶ Следующий шаг:${NC}"
echo "  Изучите OTel-инструментацию в коде: services/catalog-api/app.py"
echo "  Затем генерируйте трафик: bash scripts/05-generate-traffic.sh"
