#!/bin/bash
# =============================================================================
# Очистка: удаление ВСЕХ ресурсов стенда (приложение + мониторинг + ingress)
# =============================================================================

set -euo pipefail

NS_BOOKSHOP="bookshop"
NS_MONITORING="monitoring"
NS_INGRESS="ingress-nginx"
BOLD='\033[1m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Полная очистка стенда Bookshop                  ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Будут удалены:"
echo "  • Namespace ${NS_BOOKSHOP} (приложение, БД, данные)"
echo "  • Helm releases: promtail, loki, tempo, kube-prometheus-stack"
echo "  • Namespace ${NS_MONITORING}"
echo "  • Helm release: ingress-nginx"
echo "  • Namespace ${NS_INGRESS}"
echo ""

read -p "Вы уверены? Это действие необратимо [y/N]: " CONFIRM
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
    echo "Отменено."
    exit 0
fi

echo ""

# ---------------------------------------------------------------------------
# 1. Удаление приложения (namespace bookshop)
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 1. Удаление приложения (${NS_BOOKSHOP})${NC}"
if kubectl get namespace ${NS_BOOKSHOP} &>/dev/null; then
  kubectl delete namespace ${NS_BOOKSHOP} --grace-period=30 --timeout=120s 2>/dev/null || true
  echo -e "${GREEN}✓ Namespace ${NS_BOOKSHOP} удалён${NC}"
else
  echo -e "${YELLOW}  Namespace ${NS_BOOKSHOP} не найден — пропускаем${NC}"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Удаление Helm releases мониторинга
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 2. Удаление Helm releases мониторинга${NC}"

for RELEASE in promtail loki tempo kube-prometheus-stack; do
  if helm status ${RELEASE} -n ${NS_MONITORING} &>/dev/null; then
    echo "  Удаляем ${RELEASE}..."
    helm uninstall ${RELEASE} -n ${NS_MONITORING} --wait --timeout 5m 2>/dev/null || true
    echo -e "  ${GREEN}✓ ${RELEASE} удалён${NC}"
  else
    echo -e "  ${YELLOW}${RELEASE} не найден — пропускаем${NC}"
  fi
done
echo ""

# ---------------------------------------------------------------------------
# 3. Удаление namespace monitoring
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 3. Удаление namespace ${NS_MONITORING}${NC}"
if kubectl get namespace ${NS_MONITORING} &>/dev/null; then
  kubectl delete namespace ${NS_MONITORING} --grace-period=30 --timeout=120s 2>/dev/null || true
  echo -e "${GREEN}✓ Namespace ${NS_MONITORING} удалён${NC}"
else
  echo -e "${YELLOW}  Namespace ${NS_MONITORING} не найден — пропускаем${NC}"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Удаление Ingress Controller
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 4. Удаление ingress-nginx${NC}"
if helm status ingress-nginx -n ${NS_INGRESS} &>/dev/null; then
  helm uninstall ingress-nginx -n ${NS_INGRESS} --wait --timeout 5m 2>/dev/null || true
  echo -e "${GREEN}✓ ingress-nginx удалён${NC}"
else
  echo -e "${YELLOW}  ingress-nginx не найден — пропускаем${NC}"
fi

if kubectl get namespace ${NS_INGRESS} &>/dev/null; then
  kubectl delete namespace ${NS_INGRESS} --grace-period=30 --timeout=60s 2>/dev/null || true
  echo -e "${GREEN}✓ Namespace ${NS_INGRESS} удалён${NC}"
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Очистка CRD (опционально)
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 5. Проверка оставшихся CRD от Prometheus Operator${NC}"
CRDS=$(kubectl get crd 2>/dev/null | grep -c "monitoring.coreos.com" || true)
if [ "$CRDS" -gt 0 ]; then
  echo -e "${YELLOW}  Найдено ${CRDS} CRD от Prometheus Operator${NC}"
  read -p "  Удалить CRD? [y/N]: " CONFIRM_CRD
  if [ "${CONFIRM_CRD}" = "y" ] || [ "${CONFIRM_CRD}" = "Y" ]; then
    kubectl get crd -o name | grep monitoring.coreos.com | xargs kubectl delete 2>/dev/null || true
    echo -e "  ${GREEN}✓ CRD удалены${NC}"
  else
    echo -e "  ${YELLOW}CRD оставлены${NC}"
  fi
else
  echo -e "${GREEN}✓ CRD не найдены${NC}"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Проверка оставшихся PV
# ---------------------------------------------------------------------------
echo -e "${CYAN}▶ 6. Проверка оставшихся PersistentVolumes${NC}"
PV_COUNT=$(kubectl get pv 2>/dev/null | grep -cE "${NS_BOOKSHOP}|${NS_MONITORING}" || true)
if [ "$PV_COUNT" -gt 0 ]; then
  echo -e "${YELLOW}  Найдено ${PV_COUNT} PV:${NC}"
  kubectl get pv 2>/dev/null | grep -E "${NS_BOOKSHOP}|${NS_MONITORING}" || true
  echo -e "${YELLOW}  Удалите вручную при необходимости: kubectl delete pv <name>${NC}"
else
  echo -e "${GREEN}✓ PV очищены${NC}"
fi
echo ""

# ---------------------------------------------------------------------------
echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Очистка завершена                               ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Для повторного развёртывания:"
echo "    bash scripts/02-deploy.sh"
echo "    bash scripts/04-install-monitoring.sh"
