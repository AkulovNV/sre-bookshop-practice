#!/bin/bash
# =============================================================================
# Очистка: удаление всех ресурсов Bookshop
# =============================================================================

set -euo pipefail

NS="bookshop"
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${BOLD}Удаление приложения Bookshop...${NC}"
echo ""

read -p "Вы уверены? Будут удалены ВСЕ ресурсы в namespace '${NS}' [y/N]: " CONFIRM
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
    echo "Отменено."
    exit 0
fi

echo ""
echo "Удаление namespace ${NS} (включая все ресурсы)..."
kubectl delete namespace ${NS} --grace-period=30 --timeout=120s 2>/dev/null || true

# PV может остаться после удаления namespace
echo "Проверка оставшихся PV..."
kubectl get pv 2>/dev/null | grep ${NS} && \
    echo -e "${RED}Внимание: остались PersistentVolumes. Удалите вручную при необходимости.${NC}" || \
    echo -e "${GREEN}✓ PV очищены${NC}"

echo ""
echo -e "${GREEN}✓ Очистка завершена${NC}"
