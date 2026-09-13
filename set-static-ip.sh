#!/bin/bash
#
# set-static-ip.sh - fixa um IP estático via netplan num Ubuntu recém-instalado.
#
# Uso:
#   curl -fsSL <URL_RAW_DO_ARQUIVO> | sudo bash
# ou
#   curl -fsSL <URL_RAW_DO_ARQUIVO> -o set-static-ip.sh && sudo bash set-static-ip.sh
#
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Rode como root: sudo bash $0  (ou 'curl ... | sudo bash')"
    exit 1
fi

# Lê sempre do terminal de verdade, mesmo quando o script veio de um
# 'curl | bash' (nesse caso o stdin normal está ocupado pelo pipe do curl).
TTY=/dev/tty
if [ ! -r "$TTY" ]; then
    echo "Não encontrei um terminal interativo (/dev/tty). Baixe o arquivo e rode"
    echo "com 'bash set-static-ip.sh' em vez de usar pipe direto."
    exit 1
fi

echo "===================================================="
echo " Fixar IP estático (netplan)"
echo "===================================================="
echo ""
echo "-- Interfaces de rede atuais --"
ip -brief a
echo ""

read -rp "Nome da interface a fixar (ex: ens18): " IFACE < "$TTY"
ip link show "$IFACE" >/dev/null 2>&1 || { echo "Interface $IFACE não encontrada."; exit 1; }

read -rp "IP estático desejado (ex: 10.1.1.250): " STATIC_IP < "$TTY"
read -rp "Máscara em CIDR (ex: 24): " CIDR < "$TTY"
read -rp "Gateway (ex: 10.1.1.1): " GATEWAY < "$TTY"
read -rp "DNS, separados por vírgula (ex: 8.8.8.8,1.1.1.1): " DNS < "$TTY"

if [ -z "$STATIC_IP" ] || [ -z "$CIDR" ] || [ -z "$GATEWAY" ]; then
    echo "Dados incompletos, abortando."
    exit 1
fi

NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
if [ -z "$NETPLAN_FILE" ]; then
    echo "Erro: nenhum arquivo netplan encontrado em /etc/netplan/"
    exit 1
fi

cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%s)"
echo "-> Backup salvo: ${NETPLAN_FILE}.bak.*"

cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses:
        - ${STATIC_IP}/${CIDR}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
EOF

echo ""
echo "===================================================="
echo " Confira antes de aplicar:"
echo "   Interface : ${IFACE}"
echo "   IP        : ${STATIC_IP}/${CIDR}"
echo "   Gateway   : ${GATEWAY}"
echo "   DNS       : ${DNS}"
echo "===================================================="
read -rp "Aplicar agora? (s/N): " CONFIRM < "$TTY"

if [[ "$CONFIRM" =~ ^[sS]$ ]]; then
    netplan apply
    echo ""
    echo "-> IP estático aplicado: ${STATIC_IP}"
    echo "-> Se estava conectado via SSH no IP antigo, a sessão pode cair agora."
    echo "-> Conecte de novo em: ssh $(whoami)@${STATIC_IP}"
else
    echo "-> Config salva mas NÃO aplicada. Rode 'sudo netplan apply' quando quiser."
fi
