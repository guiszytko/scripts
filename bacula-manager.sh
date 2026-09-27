#!/bin/bash
#
# bacula-manager.sh - instalador e gerenciador do Bacula + client local
# para compartilhamentos SMB, com menu. Sobe esse arquivo UMA vez na VM
# e roda: sudo bash bacula-manager.sh
#
set -euo pipefail

MOUNT_POINT="/mnt/backup4tb"

# --------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Rode como root: sudo bash $0"
    exit 1
fi

pause() { read -rp "Pressione ENTER pra voltar ao menu..." _; }

# --------------------------------------------------------------------
# Cores
# --------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

log_ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
log_err()  { echo -e "${RED}✗ $*${RESET}"; }
log_info() { echo -e "${CYAN}$*${RESET}"; }
log_step() { echo -e "${BLUE}${BOLD}==> $*${RESET}"; }

safe_overwrite() {
    # uso: safe_overwrite <arquivo_temp> <arquivo_destino>
    # move o temp por cima do destino preservando dono e permissão originais
    # (evita que um simples 'mv' resete pra 600 root:root e quebre o
    #  acesso do usuário 'bacula' aos .conf depois do harden_server)
    local tmp="$1" dest="$2"
    local owner perm
    owner=$(stat -c '%U:%G' "$dest" 2>/dev/null || echo root:bacula)
    perm=$(stat -c '%a' "$dest" 2>/dev/null || echo 640)
    mv "$tmp" "$dest"
    chown "$owner" "$dest" 2>/dev/null || true
    chmod "$perm" "$dest" 2>/dev/null || true
}

# --------------------------------------------------------------------
# Banner (personalize o texto abaixo se quiser trocar)
# --------------------------------------------------------------------
show_banner() {
cat << 'BANNER'

  ____  _   _  ____   ____         __ _
 |  _ \| | | |/ ___| / ___|  ___  / _| |___      ____ _ _ __ ___
 | |_) | |_| | |     \___ \ / _ \| |_| __\ \ /\ / / _` | '__/ _ \
 |  _ <|  _  | |___   ___) | (_) |  _| |_ \ V  V / (_| | | |  __/
 |_| \_\_| |_|\____| |____/ \___/|_|  \__| \_/\_/ \__,_|_|  \___|

BANNER
}

# ======================================================================
# 1. Disco de 4TB
# ======================================================================
setup_disk() {
    if mountpoint -q "$MOUNT_POINT"; then
        log_ok "$MOUNT_POINT já está montado, pulando particionamento."
        return
    fi

    echo "-- Disco de backup --"
    lsblk -d -o NAME,SIZE,MODEL
    read -rp "Nome do disco de 4TB (ex: sdb, sem o /dev/): " DISK_NAME
    DISK="/dev/${DISK_NAME}"
    [ -b "$DISK" ] || { log_err "Erro: $DISK não existe."; return 1; }

    lsblk "$DISK"
    read -rp "ATENÇÃO: isso apaga $DISK. Digite SIM pra confirmar: " CONFIRM
    [ "$CONFIRM" = "SIM" ] || { log_warn "Abortado."; return 1; }

    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary ext4 0% 100%
    sleep 2
    PART="${DISK}1"
    mkfs.ext4 -F -L bacula-backup "$PART"

    mkdir -p "$MOUNT_POINT"
    UUID=$(blkid -s UUID -o value "$PART")
    grep -q "$UUID" /etc/fstab || echo "UUID=$UUID  $MOUNT_POINT  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10  0  2" >> /etc/fstab
    mount -a
    log_ok "Disco pronto em $MOUNT_POINT (persistente após reboot via /etc/fstab)"
}

# ======================================================================
# 2. Instalação dos pacotes
# ======================================================================
install_packages() {
    if command -v bacula-dir >/dev/null 2>&1; then
        log_ok "Bacula já compilado, pulando compilação."
    else
    log_step "Instalando dependências de compilação"
    apt-get update -qq
    apt-get install -y build-essential libpq-dev libssl-dev python3-dev postgresql \
        postgresql-contrib wget mc

    log_step "Baixando o código-fonte do Bacula 15.0.3"
    cd /usr/local/src || return 1
    if [ ! -f bacula-15.0.3.tar.gz ]; then
        wget -q https://sourceforge.net/projects/bacula/files/bacula/15.0.3/bacula-15.0.3.tar.gz \
            -O bacula-15.0.3.tar.gz || { log_err "Falha ao baixar o código-fonte."; return 1; }
    fi
    tar -xzf bacula-15.0.3.tar.gz
    cd bacula-15.0.3 || return 1

    log_step "Compilando (./configure + make - pode demorar vários minutos)"
    ./configure --sbindir=/usr/sbin --sysconfdir=/etc/bacula \
        --with-working-dir=/var/lib/bacula --with-pid-dir=/var/run/bacula \
        --with-logdir=/var/log/bacula \
        --enable-postgresql --with-postgresql --enable-bwx-console \
        --enable-smart-alloc --with-openssl --with-python \
        || { log_err "./configure falhou. Veja o erro acima."; return 1; }

    make -j"$(nproc)" || { log_err "make falhou. Veja o erro acima."; return 1; }
    make install || { log_err "make install falhou. Veja o erro acima."; return 1; }

    log_ok "Bacula 15.0.3 compilado e instalado."
    fi

    if sudo -u postgres psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw bacula; then
        log_ok "Catálogo 'bacula' já existe no PostgreSQL, pulando criação."
    else
    log_step "Sincronizando fuso horário do PostgreSQL com o sistema"
    SYS_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    sudo -u postgres psql -c "ALTER SYSTEM SET timezone TO '${SYS_TZ}';" >/dev/null 2>&1 || true
    systemctl restart postgresql
    sleep 1

    log_step "Ajustando autenticação do PostgreSQL (peer -> md5 para conexões locais)"
    PG_VERSION=$(ls /etc/postgresql/ 2>/dev/null | head -1)
    if [ -n "$PG_VERSION" ]; then
        PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
        if [ -f "$PG_HBA" ]; then
            sed -i "s/local\s*all\s*all\s*peer/local all all md5/" "$PG_HBA"
            systemctl restart postgresql
            sleep 2
        fi
    fi

    log_step "Criando o catálogo no PostgreSQL"
    DBPASS=$(openssl rand -base64 18)
    cd /etc/bacula || return 1

    if [ ! -f create_postgresql_database ]; then
        log_err "Scripts de catálogo não encontrados em /etc/bacula/. Confira a compilação."
        return 1
    fi

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='bacula'" | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER bacula WITH PASSWORD '${DBPASS}' CREATEDB;"
    sudo -u postgres psql -c "ALTER USER bacula WITH PASSWORD '${DBPASS}';"

    sudo -u postgres ./create_postgresql_database -U bacula
    sudo -u postgres ./make_postgresql_tables -U bacula
    sudo -u postgres ./grant_postgresql_privileges -U bacula

    log_step "Atualizando a senha do catálogo em bacula-dir.conf"
    sed -i "s/dbpassword = \"[^\"]*\"/dbpassword = \"${DBPASS}\"/" /etc/bacula/bacula-dir.conf
    sed -i "s/dbname = \"[^\"]*\"/dbname = \"bacula\"/" /etc/bacula/bacula-dir.conf
    sed -i "s/dbuser = \"[^\"]*\"/dbuser = \"bacula\"/" /etc/bacula/bacula-dir.conf

    echo "$DBPASS" > /root/.bacula-catalog-password
    chmod 600 /root/.bacula-catalog-password
    fi

    log_step "Criando usuário de sistema 'bacula'"
    id -u bacula >/dev/null 2>&1 || useradd -r -s /bin/false bacula

    log_step "Criando serviços systemd"
    mkdir -p /var/lib/bacula /var/run/bacula /var/log/bacula
    chown -R bacula:bacula /var/lib/bacula /var/run/bacula /var/log/bacula 2>/dev/null || true

    cat > /etc/systemd/system/bacula-director.service <<'EOF'
[Unit]
Description=Bacula Director
After=network.target postgresql.service

[Service]
Type=forking
ExecStart=/usr/sbin/bacula-dir -c /etc/bacula/bacula-dir.conf
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/bacula-sd.service <<'EOF'
[Unit]
Description=Bacula Storage Daemon
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/bacula-sd -c /etc/bacula/bacula-sd.conf
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/bacula-fd.service <<'EOF'
[Unit]
Description=Bacula File Daemon
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/bacula-fd -c /etc/bacula/bacula-fd.conf
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bacula-director bacula-sd bacula-fd

    log_step "Preparando diretórios de volumes"
    log_step "Desabilitando TLS/TLS-PSK nos blocos padrão (evita bug de negociação"
    log_step "entre builds diferentes de OpenSSL Linux/Windows)"
    for RES in "Storage {" "Director {"; do
        LINES=$(grep -n "^${RES}" /etc/bacula/bacula-sd.conf | cut -d: -f1)
        for LN in $(echo "$LINES" | sort -rn); do
            if ! sed -n "$((LN+1))p" /etc/bacula/bacula-sd.conf | grep -q "TLS Enable"; then
                sed -i "${LN}a\\  TLS Enable = no\\n  TLS PSK Enable = no" /etc/bacula/bacula-sd.conf
            fi
        done
    done

    mkdir -p "$MOUNT_POINT/bacula-volumes"
    chown -R bacula:bacula "$MOUNT_POINT/bacula-volumes" 2>/dev/null || true
    mkdir -p /var/lib/bacula/cloud-cache
    chown -R bacula:bacula /var/lib/bacula/cloud-cache 2>/dev/null || true

    log_ok "Bacula 15.0.3 instalado, catálogo criado. Senha do catálogo em /root/.bacula-catalog-password"
}

# ======================================================================
# 3. Configuração base (client Windows/local + fileset + storage local + jobs)
#    Bacula usa arquivos monolíticos (bacula-dir.conf / bacula-sd.conf) -
#    aqui a gente ANEXA blocos no final desses arquivos.
# ======================================================================
generate_base_config() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    SD_CONF="/etc/bacula/bacula-sd.conf"

    if grep -q "^Storage {" "$SD_CONF" 2>/dev/null && grep -q "Name = Local-Backup-Device" "$SD_CONF" 2>/dev/null; then
        log_ok "Device local já configurado, pulando (esta função só sabe adicionar, nunca substituir)."
        echo "Se precisar mudar algo, use a opção de reparo/dedupe ou edite manualmente."
        return
    fi

    STORAGE_PASSWORD=$(openssl rand -base64 24)

    log_step "Adicionando Device local no Storage Daemon"
    cat >> "$SD_CONF" <<EOF

Device {
  Name = Local-Backup-Device
  Media Type = File
  Archive Device = ${MOUNT_POINT}/bacula-volumes
  LabelMedia = yes
  Random Access = yes
  AutomaticMount = yes
  RemovableMedia = no
  AlwaysOpen = no
}
EOF

    log_step "Adicionando Storage no Director"
    cat >> "$DIR_CONF" <<EOF

Storage {
  Name = Local-Backup-Storage
  Address = 127.0.0.1
  Password = "${STORAGE_PASSWORD}"
  Device = Local-Backup-Device
  Media Type = File
  TLS Enable = no
  TLS PSK Enable = no
}

Pool {
  Name = Local-Pool
  Pool Type = Backup
  Storage = Local-Backup-Storage
  Volume Retention = 45 days
  Label Format = "Local-\${Year}\${Month:p/2/0/r}\${Day:p/2/0/r}-\${NumVols}"
  Recycle = yes
}
EOF

    log_step "Sincronizando a senha com o Director no bacula-sd.conf"
    SELF_DIR_NAME=$(grep -A2 "^Director {" "$DIR_CONF" | grep -oP '(?<=Name = )\S+' | head -1)
    if [ -n "$SELF_DIR_NAME" ] && grep -q "Name = ${SELF_DIR_NAME}$" "$SD_CONF"; then
        sed -i "/Name = ${SELF_DIR_NAME}$/,/^}/ s|Password = \"[^\"]*\"|Password = \"${STORAGE_PASSWORD}\"|" "$SD_CONF"
        log_ok "Senha sincronizada no bacula-sd.conf (Director ${SELF_DIR_NAME})."
    else
        log_warn "Não achei o Director '${SELF_DIR_NAME}' no bacula-sd.conf pra sincronizar a senha."
        log_warn "Confira manualmente se as senhas batem, senão o Director não autentica no Storage local."
    fi

    log_step "Sincronizando a mesma senha nos Autochanger padrão (File1/File2) do bacula-dir.conf"
    for AC_NAME in File1 File2; do
        if grep -q "Name = ${AC_NAME}$" "$DIR_CONF"; then
            sed -i "/Name = ${AC_NAME}$/,/^}/ s|Password = \"[^\"]*\"|Password = \"${STORAGE_PASSWORD}\"|" "$DIR_CONF"
        fi
    done
    log_ok "Autochanger padrão sincronizados (evita erro no job BackupCatalog)."

    # guarda a senha de auth Director<->Storage num lugar fácil de reler depois
    echo "$STORAGE_PASSWORD" > /root/.bacula-sd-password
    chmod 600 /root/.bacula-sd-password

    log_ok "Configuração base pronta (Device local + Pool)."
    echo "Use a opção 8 pra criar o primeiro job de backup."
}

# ======================================================================
# 4. Ativar OCI (Cloud storage - suportado nativamente no Bacula Community)
# ======================================================================
configure_oci() {
    if [ ! -f /etc/bacula/bacula-dir.conf ]; then
        log_err "Erro: rode a opção 1 (instalação base) primeiro."
        return 1
    fi

    echo "-- Backup pra OCI Object Storage (via rclone) --"
    echo "O Bacula grava só localmente; o rclone sincroniza os volumes pra"
    echo "OCI de forma independente, agendado via cron. Isso evita o driver"
    echo "de nuvem nativo do Bacula, que exige compilar libs3 e tem bugs"
    echo "conhecidos de build nessa versão."
    echo ""
    echo "Você precisa ter em mãos: namespace, região, nome do bucket já criado,"
    echo "e as Customer Secret Keys (Access Key + Secret Key) da OCI."
    read -rp "Tem tudo isso em mãos agora? (s/N): " OCI_READY
    if [[ ! "$OCI_READY" =~ ^[sS]$ ]]; then
        log_warn "Cancelado. Nada foi alterado. Rode esta opção de novo quando tiver os dados."
        return 0
    fi

    read -rp "Namespace da OCI: " OCI_NAMESPACE
    read -rp "Região da OCI (ex: sa-vinhedo-1): " OCI_REGION
    read -rp "Nome do bucket na OCI: " OCI_BUCKET
    read -rp "Customer Secret Key ID: " OCI_ACCESS_KEY
    read -rp "Customer Secret Key: " OCI_SECRET_KEY
    if [ -z "$OCI_SECRET_KEY" ]; then
        log_err "Secret Key veio vazia. Abortando pra não gravar config quebrada."
        return 1
    fi
    log_ok "Secret Key recebida (${#OCI_SECRET_KEY} caracteres)."
    read -rp "Nome da 'pasta' dentro do bucket pra guardar os backups [bacula-backup]: " OCI_FOLDER
    OCI_FOLDER=${OCI_FOLDER:-bacula-backup}
    read -rp "Horário pra rodar a sincronização diária [01:00]: " SYNC_TIME
    SYNC_TIME=${SYNC_TIME:-01:00}
    SYNC_HOUR=$(echo "$SYNC_TIME" | cut -d: -f1)
    SYNC_MIN=$(echo "$SYNC_TIME" | cut -d: -f2)

    log_step "Instalando rclone"
    command -v rclone >/dev/null 2>&1 || apt-get install -y rclone

    OCI_ENDPOINT="https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oci.customer-oci.com"

    log_step "Configurando o remote 'oci-backup' no rclone"
    mkdir -p /root/.config/rclone
    if rclone listremotes 2>/dev/null | grep -q "^oci-backup:"; then
        rclone config update oci-backup \
            access_key_id="$OCI_ACCESS_KEY" \
            secret_access_key="$OCI_SECRET_KEY" \
            endpoint="$OCI_ENDPOINT" \
            region="$OCI_REGION" \
            force_path_style=true
    else
        rclone config create oci-backup s3 \
            provider=Other \
            access_key_id="$OCI_ACCESS_KEY" \
            secret_access_key="$OCI_SECRET_KEY" \
            endpoint="$OCI_ENDPOINT" \
            region="$OCI_REGION" \
            force_path_style=true
    fi

    log_step "Testando a conexão com o bucket"
    if rclone ls "oci-backup:${OCI_BUCKET}" >/dev/null 2>&1; then
        log_ok "Conexão com o bucket '${OCI_BUCKET}' funcionando."
    else
        log_err "Não consegui acessar o bucket. Confira namespace/região/bucket/chaves."
        log_err "Teste manual: rclone ls oci-backup:${OCI_BUCKET}"
        return 1
    fi

    log_step "Criando o agendamento (cron) da sincronização diária"
    # --s3-chunk-size 256M: com o limite de 10.000 partes do S3/OCI, um chunk
    #   de 64M só cobre arquivos até ~640GB - insuficiente pra volumes grandes
    #   (ex: 1TB+). 256M cobre com folga até ~2.5TB por arquivo.
    # flock: evita uma segunda execução começar antes da anterior terminar
    #   (sincronizações grandes podem legitimamente levar mais de 1 dia).
    cat > /etc/cron.d/rclone-backup-oci <<EOF
# Sincroniza os volumes locais do Bacula com a OCI, todo dia.
# Gerado por bacula-manager.sh
${SYNC_MIN} ${SYNC_HOUR} * * * root /usr/bin/flock -n /var/run/rclone-backup.lock /usr/bin/rclone sync ${MOUNT_POINT}/bacula-volumes oci-backup:${OCI_BUCKET}/${OCI_FOLDER}/ --s3-chunk-size 256M --s3-upload-concurrency 8 --transfers 4 --log-file=/var/log/rclone-backup.log --log-level INFO
EOF
    chmod 644 /etc/cron.d/rclone-backup-oci
    touch /var/log/rclone-backup.log

    # Remove blocos antigos do driver de nuvem nativo do Bacula, se existirem
    # de uma tentativa anterior (não funcionam sem libs3 compilado)
    if grep -q "OCI-Cloud-Storage\|OCI-Cloud-Device" /etc/bacula/bacula-dir.conf /etc/bacula/bacula-sd.conf 2>/dev/null; then
        log_warn "Encontrei configuração antiga do driver de nuvem nativo do Bacula"
        log_warn "(que não funciona sem compilar libs3). Ela fica inofensiva parada"
        log_warn "no arquivo, mas se quiser remover, use a opção 13 (Reparar config)"
        log_warn "ou peça ajuda pra gerar o comando de limpeza."
    fi

    log_ok "Backup pra OCI configurado via rclone."
    echo ""
    echo "Sincroniza todo dia às ${SYNC_TIME} (via cron)."
    echo "Pasta no bucket: ${OCI_FOLDER}/"
    echo ""
    echo "Pra rodar manualmente agora (primeira vez manda tudo, é normal):"
    echo "  sudo flock -n /var/run/rclone-backup.lock rclone sync ${MOUNT_POINT}/bacula-volumes oci-backup:${OCI_BUCKET}/${OCI_FOLDER}/ --s3-chunk-size 256M --s3-upload-concurrency 8 --transfers 4 --progress"
    echo ""
    echo "Pra ver o log da última sincronização:"
    echo "  sudo tail -f /var/log/rclone-backup.log"
}



# ======================================================================
# 5. Serviços
# ======================================================================
restart_services() {
    log_step "Validando configuração"
    bacula-dir -t -c /etc/bacula/bacula-dir.conf
    bacula-sd -t -c /etc/bacula/bacula-sd.conf
    log_step "Reiniciando serviços"
    systemctl enable --now postgresql 2>/dev/null || true
    systemctl restart bacula-director bacula-sd bacula-fd
    log_ok "Serviços reiniciados."
}

# ======================================================================
# 6. Instalação completa
# ======================================================================
full_install() {
    setup_disk
    install_packages
    generate_base_config
    install_bacularis
    read -rp "Quer configurar a OCI agora? (s/N): " ans
    if [[ "$ans" =~ ^[sS]$ ]]; then
        configure_oci
    else
        log_warn "Pulando OCI. Rode a opção 2 do menu quando tiver o bucket."
    fi
    restart_services
    harden_server
}

# ======================================================================
# 7. Fixar IP estático (idêntico ao Bareos)
# ======================================================================
configure_static_ip() {
    echo "-- Interfaces de rede atuais --"
    ip -brief a
    echo ""
    read -rp "Nome da interface a fixar (ex: ens18): " IFACE
    ip link show "$IFACE" >/dev/null 2>&1 || { log_err "Interface $IFACE não encontrada."; return 1; }

    read -rp "IP estático desejado (ex: 10.1.1.250): " STATIC_IP
    read -rp "Máscara em CIDR (ex: 24): " CIDR
    read -rp "Gateway (ex: 10.1.1.1): " GATEWAY
    read -rp "DNS, separados por vírgula (ex: 8.8.8.8,1.1.1.1): " DNS
    [ -n "$STATIC_IP" ] && [ -n "$CIDR" ] && [ -n "$GATEWAY" ] || { log_err "Dados incompletos, abortando."; return 1; }

    NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    [ -n "$NETPLAN_FILE" ] || { log_err "Nenhum arquivo netplan encontrado."; return 1; }

    cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%s)"
    log_ok "Backup salvo: ${NETPLAN_FILE}.bak.*"

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

    read -rp "Aplicar agora? (s/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[sS]$ ]]; then
        netplan apply
        log_ok "IP estático aplicado: ${STATIC_IP}/${CIDR}"
    else
        log_warn "Config salva mas NÃO aplicada. Rode 'sudo netplan apply' quando quiser."
    fi
}

# ======================================================================
# 8. Montar compartilhamento SMB do Windows (via CIFS)
# ======================================================================
full_purge() {
    echo "===================================================="
    echo -e "${RED}${BOLD} ATENÇÃO: isso remove TUDO${RESET}"
    echo "===================================================="
    echo "Vai desinstalar: Bacula (director/sd/fd/console), Bacularis,"
    echo "Apache, o banco 'bacula' no PostgreSQL, e todos os .conf,"
    echo "senhas salvas e credenciais geradas pelo script."
    echo ""
    echo "O disco de 4TB (${MOUNT_POINT}) e os volumes de backup NÃO"
    echo "são apagados — só a configuração do Bacula em si."
    echo ""
    read -rp "Digite CONFIRMAR (maiúsculo) pra prosseguir: " CONFIRM
    if [ "$CONFIRM" != "CONFIRMAR" ]; then
        log_warn "Abortado, nada foi removido."
        return
    fi

    log_step "Parando e desabilitando serviços"
    systemctl stop bacula-director bacula-sd bacula-fd apache2 nginx 2>/dev/null || true
    systemctl disable bacula-director bacula-sd bacula-fd 2>/dev/null || true

    log_step "Removendo binários e unidades systemd do Bacula compilado"
    rm -f /usr/sbin/bacula-dir /usr/sbin/bacula-sd /usr/sbin/bacula-fd /usr/sbin/bconsole \
        /usr/sbin/bdirjson /usr/sbin/bsdjson /usr/sbin/bfdjson /usr/sbin/bbconsjson \
        /usr/sbin/dbcheck /usr/sbin/bwx-console 2>/dev/null || true
    rm -f /etc/systemd/system/bacula-director.service \
        /etc/systemd/system/bacula-sd.service \
        /etc/systemd/system/bacula-fd.service
    systemctl daemon-reload

    log_step "Removendo pacotes (Apache/Baculum antigos, se sobrou algo)"
    apt-get purge -y bacula-director bacula-director-pgsql bacula-sd bacula-fd \
        bacula-console bacula-server bacula-common bacula-common-pgsql bacula-bscan \
        baculum-common baculum-api baculum-api-apache2 baculum-web baculum-web-apache2 \
        apache2 apache2-bin apache2-data apache2-utils 2>/dev/null || true

    log_step "Removendo arquivos de configuração, fonte compilado e credenciais"
    rm -rf /etc/bacula /etc/baculum /usr/share/baculum /var/cache/baculum \
        /var/lib/bacula /var/log/bacula /var/run/bacula \
        /usr/local/src/bacula-15.0.3 /usr/local/src/bacula-15.0.3.tar.gz \
        /opt/bacularis /usr/share/bacularis /etc/bacularis \
        /root/.bacula-sd-password /root/.bacula-catalog-password /root/bacula-install-credentials.txt \
        /etc/apache2/sites-available/baculum*.conf \
        /etc/nginx/sites-available/bacularis.conf /etc/nginx/sites-enabled/bacularis.conf \
        /etc/apt/sources.list.d/baculum.list /usr/share/keyrings/baculum.gpg \
        /etc/sudoers.d/baculum-api /etc/sudoers.d/bacularis
    systemctl reload nginx 2>/dev/null || true

    log_step "Removendo usuário de sistema 'bacula'"
    userdel bacula 2>/dev/null || true

    log_step "Removendo banco de dados do catálogo"
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS bacula;" 2>/dev/null || true
    sudo -u postgres psql -c "DROP USER IF EXISTS bacula;" 2>/dev/null || true

    log_step "Limpando pacotes órfãos"
    apt-get autoremove -y

    log_ok "Tudo removido. O disco ${MOUNT_POINT} e o /etc/fstab NÃO foram mexidos."
    echo "Pra reinstalar do zero, rode a opção 1."
}

setup_disk_alert() {
    log_step "Configurando alerta de espaço em disco"

    read -rp "Alertar quando o disco raiz (/) passar de quantos % de uso? [85]: " THRESHOLD
    THRESHOLD=${THRESHOLD:-85}

    cat > /usr/local/bin/check-disk-space.sh <<EOF
#!/bin/bash
# Gerado por bacula-manager.sh - alerta de espaço em disco
THRESHOLD=${THRESHOLD}

for MOUNT in / ${MOUNT_POINT}; do
    USED=\$(df --output=pcent "\$MOUNT" 2>/dev/null | tail -1 | tr -d ' %')
    if [ -n "\$USED" ] && [ "\$USED" -ge "\$THRESHOLD" ]; then
        logger -t disk-space-alert -p user.warning "ALERTA: \$MOUNT está com \${USED}% de uso (limite: \${THRESHOLD}%)"
    fi
done
EOF
    chmod +x /usr/local/bin/check-disk-space.sh

    cat > /etc/cron.d/disk-space-alert <<'EOF'
# Checa espaço em disco a cada 2 horas, gera alerta no syslog se passar do limite
0 */2 * * * root /usr/local/bin/check-disk-space.sh
EOF
    chmod 644 /etc/cron.d/disk-space-alert

    log_step "Configurando aviso na tela de login (SSH)"
    cat > /etc/update-motd.d/95-disk-space <<EOF
#!/bin/bash
THRESHOLD=${THRESHOLD}
for MOUNT in / ${MOUNT_POINT}; do
    USED=\$(df --output=pcent "\$MOUNT" 2>/dev/null | tail -1 | tr -d ' %')
    if [ -n "\$USED" ] && [ "\$USED" -ge "\$THRESHOLD" ]; then
        echo -e "\033[1;31m⚠ AVISO: \$MOUNT está com \${USED}% de uso de disco (limite: \${THRESHOLD}%)\033[0m"
    fi
done
EOF
    chmod +x /etc/update-motd.d/95-disk-space

    log_ok "Alerta configurado: checa a cada 2h (syslog) e mostra aviso ao logar via SSH se passar de ${THRESHOLD}%."
    echo "Pra ver alertas já registrados: sudo journalctl -t disk-space-alert"
}

harden_server() {
    log_step "Instalando e configurando UFW"
    command -v ufw >/dev/null 2>&1 || apt-get install -y ufw

    ufw allow OpenSSH comment 'SSH'
    ufw allow 9101/tcp comment 'Bacula Director'
    ufw allow 9102/tcp comment 'Bacula File Daemon'
    ufw allow 9103/tcp comment 'Bacula Storage Daemon'

    if [ -d /opt/bacularis ]; then
        ufw allow 9097/tcp comment 'Bacularis'
    fi

    ufw --force enable
    log_ok "UFW ativado."
    ufw status verbose

    log_step "Ajustando permissões dos arquivos de configuração"
    if [ -d /etc/bacula ]; then
        chown -R root:bacula /etc/bacula 2>/dev/null || true
        chmod 750 /etc/bacula
        find /etc/bacula -maxdepth 1 -type f -name "*.conf" -exec chmod 640 {} \;
    fi
    [ -f /root/.bacula-sd-password ] && chmod 600 /root/.bacula-sd-password
    [ -f /root/bacula-install-credentials.txt ] && chmod 600 /root/bacula-install-credentials.txt
    for f in /etc/bacula-smb-*.creds; do
        [ -f "$f" ] && chmod 600 "$f"
    done

    log_ok "Permissões ajustadas (configs com senha não ficam legíveis por outros usuários)."
}

dedupe_conf_file() {
    local FILE="$1"
    [ -f "$FILE" ] || return
    local TMP
    local ORIG_OWNER ORIG_PERM
    ORIG_OWNER=$(stat -c '%U:%G' "$FILE" 2>/dev/null || echo root:bacula)
    ORIG_PERM=$(stat -c '%a' "$FILE" 2>/dev/null || echo 640)
    TMP=$(mktemp)
    awk '
      /^[A-Za-z]+[[:space:]]*{/ { rtype=$1; buf=$0"\n"; name=""; capturing=1; next }
      capturing {
        buf = buf $0 "\n"
        if ($0 ~ /Name[[:space:]]*=/ && name=="") { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); name=line }
        if ($0 ~ /^}/) {
          key = rtype "|" name
          if (!(key in seen)) { printf "%s", buf; seen[key]=1 }
          capturing=0; buf=""; next
        }
        next
      }
      { print }
    ' "$FILE" > "$TMP"
    mv "$TMP" "$FILE"
    chown "$ORIG_OWNER" "$FILE" 2>/dev/null || true
    chmod "$ORIG_PERM" "$FILE" 2>/dev/null || true
}

repair_config() {
    log_step "Procurando e removendo recursos duplicados (mantém a primeira ocorrência de cada)"
    dedupe_conf_file /etc/bacula/bacula-dir.conf
    dedupe_conf_file /etc/bacula/bacula-sd.conf
    log_ok "Deduplicação concluída."

    log_step "Validando"
    if bacula-dir -t -c /etc/bacula/bacula-dir.conf && bacula-sd -t -c /etc/bacula/bacula-sd.conf; then
        log_ok "Configuração válida. Reiniciando serviços."
        systemctl restart bacula-director bacula-sd bacula-fd
    else
        log_err "Ainda há erro de configuração — pode ser outro problema além de duplicação. Veja a mensagem acima."
    fi
}

change_client_ip() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    echo "-- Clients --"
    awk '/^Client[[:space:]]*{/{f=1} f && /Name[[:space:]]*=/{line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); print line; f=0}' "$DIR_CONF"
    echo ""
    read -rp "Nome do client: " CLI
    read -rp "Novo IP: " NEWIP
    [ -n "$NEWIP" ] || { log_err "IP vazio, abortando."; return 1; }

    TMP=$(mktemp)
    awk -v target="$CLI" -v newip="$NEWIP" '
      /^Client[[:space:]]*{/ { in_client=1; namebuf=""; block=$0 "\n"; next }
      {
        if (in_client) {
          if ($0 ~ /Name[[:space:]]*=/ && namebuf=="") { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); namebuf=line }
          block = block $0 "\n"
          if ($0 ~ /^}/) {
            if (namebuf==target) { gsub(/Address[[:space:]]*=[^\n]*/, "Address = " newip, block) }
            printf "%s", block
            in_client=0; block=""; namebuf=""
            next
          }
          next
        }
        print
      }
    ' "$DIR_CONF" > "$TMP"
    safe_overwrite "$TMP" "$DIR_CONF"

    bacula-dir -t -c "$DIR_CONF"
    systemctl restart bacula-director
    log_ok "IP do client ${CLI} atualizado para ${NEWIP}."
}

edit_fileset() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    echo "-- FileSets existentes --"
    awk '/^FileSet[[:space:]]*{/{f=1} f && /Name[[:space:]]*=/{line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); print line; f=0}' "$DIR_CONF"
    echo ""
    read -rp "Nome do FileSet a editar: " FSNAME
    read -rp "Caminho a adicionar (ex: E:/ ou /mnt/win-x): " NEWPATH
    [ -n "$NEWPATH" ] || { log_err "Vazio, abortando."; return 1; }

    TMP=$(mktemp)
    awk -v target="$FSNAME" -v newpath="$NEWPATH" '
      /^FileSet[[:space:]]*{/ { in_fs=1; namebuf=""; block=$0 "\n"; inserted=0; next }
      {
        if (in_fs) {
          if ($0 ~ /Name[[:space:]]*=/ && namebuf=="") { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); namebuf=line }
          if (namebuf==target && !inserted && $0 ~ /^  }/) {
            block = block "    File = \"" newpath "\"\n"
            inserted=1
          }
          block = block $0 "\n"
          if ($0 ~ /^}/) {
            printf "%s", block
            in_fs=0; block=""; namebuf=""; inserted=0
            next
          }
          next
        }
        print
      }
    ' "$DIR_CONF" > "$TMP"
    safe_overwrite "$TMP" "$DIR_CONF"

    bacula-dir -t -c "$DIR_CONF"
    systemctl restart bacula-director
    log_ok "Caminho '${NEWPATH}' adicionado ao FileSet ${FSNAME}."
}

edit_prejob_command() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    echo "-- Jobs existentes --"
    awk '/^Job[[:space:]]*{/{f=1} f && /Name[[:space:]]*=/{line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); print line; f=0}' "$DIR_CONF"
    echo ""
    read -rp "Nome do job a editar: " JOBNAME
    read -rp "Novo comando pré-backup: " NEWCMD
    [ -n "$NEWCMD" ] || { log_err "Vazio, abortando."; return 1; }

    TMP=$(mktemp)
    awk -v target="$JOBNAME" -v newcmd="$NEWCMD" '
      /^Job[[:space:]]*{/ { in_job=1; namebuf=""; block=$0 "\n"; replaced=0; next }
      {
        if (in_job) {
          if ($0 ~ /Name[[:space:]]*=/ && namebuf=="") { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); namebuf=line }
          if (namebuf==target && $0 ~ /Client Run Before Job/) {
            block = block "  Client Run Before Job = \"" newcmd "\"\n"
            replaced=1
          } else {
            block = block $0 "\n"
          }
          if ($0 ~ /^}/) {
            if (namebuf==target && !replaced) {
              sub(/}\n$/, "  Client Run Before Job = \"" newcmd "\"\n}\n", block)
            }
            printf "%s", block
            in_job=0; block=""; namebuf=""; replaced=0
            next
          }
          next
        }
        print
      }
    ' "$DIR_CONF" > "$TMP"
    safe_overwrite "$TMP" "$DIR_CONF"

    bacula-dir -t -c "$DIR_CONF"
    systemctl restart bacula-director
    log_ok "Comando pré-backup do job ${JOBNAME} atualizado."
}

install_bacularis() {
    if [ -d /opt/bacularis ]; then
        log_ok "Bacularis já instalado em /opt/bacularis, pulando instalação."
        return
    fi

    if [ ! -f /etc/bacula/bacula-dir.conf ]; then
        log_err "Bacula ainda não instalado. Rode a opção 1 primeiro."
        return 1
    fi

    if dpkg -l apache2 2>/dev/null | grep -q ^ii; then
        log_step "Removendo Apache (não é mais necessário, o Bacularis usa Nginx)"
        systemctl stop apache2 2>/dev/null || true
        apt-get purge -y apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php* 2>/dev/null || true
        apt-get autoremove -y
        rm -rf /etc/apache2
    fi

    log_step "Instalando Nginx, PHP-FPM e dependências"
    apt-get update -qq
    apt-get install -y nginx php-fpm php-bcmath php-cli php-curl php-xml php-json \
        php-ldap php-mysql php-pdo php-pgsql php-intl patch expect curl unzip git

    log_step "Instalando o Composer (gerenciador de pacotes PHP)"
    if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi

    log_step "Baixando e instalando o Bacularis via Composer (pode demorar alguns minutos)"
    if ! COMPOSER_ALLOW_SUPERUSER=1 composer create-project bacularis/bacularis-app /opt/bacularis --no-interaction; then
        log_err "Falha ao baixar o Bacularis via Composer. Veja o erro acima."
        return 1
    fi

    log_step "Detectando o socket do PHP-FPM"
    PHP_SOCK=$(find /run/php* -name '*.sock' 2>/dev/null | head -1)
    if [ -z "$PHP_SOCK" ]; then
        log_err "Não encontrei o socket do PHP-FPM. Confira manualmente com: find /run/php* -name '*.sock'"
        return 1
    fi
    log_ok "Socket encontrado: ${PHP_SOCK}"

    log_step "Rodando o instalador oficial (respondendo Nginx + usuário www-data automaticamente)"
    printf "2\nwww-data\n" | bash /opt/bacularis/protected/tools/install.sh -p "$PHP_SOCK"

    GENERATED_CONF=$(find /opt/bacularis -maxdepth 1 -iname "bacularis-nginx.conf" | head -1)
    if [ -z "$GENERATED_CONF" ]; then
        log_err "O instalador não gerou o arquivo bacularis-nginx.conf esperado."
        log_err "Confira manualmente em /opt/bacularis/"
        return 1
    fi

    log_step "Movendo a config gerada para o Nginx"
    mv "$GENERATED_CONF" /etc/nginx/sites-available/bacularis.conf
    ln -sf /etc/nginx/sites-available/bacularis.conf /etc/nginx/sites-enabled/bacularis.conf

    log_step "Criando atalhos de configuração (/etc/bacularis) para os recursos extras"
    mkdir -p /etc/bacularis
    ln -sf /opt/bacularis/protected/API/Config /etc/bacularis/API
    ln -sf /opt/bacularis/protected/Web/Config /etc/bacularis/Web
    ln -sf /opt/bacularis /usr/share/bacularis

    log_step "Configurando acesso do www-data ao bconsole (sudoers)"
    SUDOERS_FILE="/etc/sudoers.d/bacularis"
    cat > "$SUDOERS_FILE" <<EOF
Defaults:www-data !requiretty
www-data ALL = (root) NOPASSWD: /usr/sbin/bdirjson
www-data ALL = (root) NOPASSWD: /usr/sbin/bsdjson
www-data ALL = (root) NOPASSWD: /usr/sbin/bfdjson
www-data ALL = (root) NOPASSWD: /usr/sbin/bbconsjson
www-data ALL = (root) NOPASSWD: /usr/sbin/bconsole
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl start bacula-dir
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl stop bacula-dir
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl restart bacula-dir
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl start bacula-sd
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl stop bacula-sd
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl restart bacula-sd
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl start bacula-fd
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl stop bacula-fd
www-data ALL = (root) NOPASSWD: /usr/sbin/systemctl restart bacula-fd
EOF
    chmod 440 "$SUDOERS_FILE"
    if ! visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
        log_err "Arquivo sudoers com sintaxe inválida, removendo por segurança."
        rm -f "$SUDOERS_FILE"
    else
        log_ok "sudoers configurado e validado."
    fi
    usermod -a -G root www-data

    log_step "Validando e reiniciando Nginx + PHP-FPM"
    if ! nginx -t; then
        log_err "Config do Nginx com erro de sintaxe. Confira /etc/nginx/sites-available/bacularis.conf"
        return 1
    fi
    systemctl restart php*-fpm 2>/dev/null || systemctl restart php-fpm
    systemctl restart nginx

    SERVER_IP=$(hostname -I | awk '{print $1}')
    {
        echo ""
        echo "Bacularis (http://${SERVER_IP}:9097/):"
        echo "  Usuário: admin"
        echo "  Senha:   admin (TROQUE no primeiro acesso)"
    } >> /root/bacula-install-credentials.txt
    chmod 600 /root/bacula-install-credentials.txt

    log_ok "Bacularis instalado e configurado (Nginx)."
    echo ""
    echo "Acesse: http://${SERVER_IP}:9097"
    echo "Usuário: admin  |  Senha: admin"
    echo "TROQUE a senha padrão assim que logar pela primeira vez."
    echo ""
    echo "Libere a porta 9097 no firewall/NAT se for acessar de fora da rede local."
}

# ======================================================================
# 9. Criar novo job de backup (passo a passo) - genérico
# ======================================================================
# ======================================================================
# ======================================================================
# ======================================================================
delete_job() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    echo "-- Jobs cadastrados --"
    JOBS=$(awk '
      /^Job[[:space:]]*{/ { in_job=1; name=""; next }
      in_job && /Name[[:space:]]*=/ && name=="" { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); name=line }
      /^}/ { if (in_job && name!="") print name; in_job=0; name="" }
    ' "$DIR_CONF")

    if [ -z "$JOBS" ]; then
        log_warn "Nenhum job cadastrado."
        return
    fi

    i=1
    declare -A JOB_MAP
    while IFS= read -r JNAME; do
        echo " ${i}) ${JNAME}"
        JOB_MAP[$i]="$JNAME"
        i=$((i+1))
    done <<< "$JOBS"

    echo ""
    read -rp "Qual número excluir (ENTER pra cancelar): " CHOICE
    [ -z "$CHOICE" ] && { log_warn "Cancelado."; return 0; }

    TARGET="${JOB_MAP[$CHOICE]:-}"
    if [ -z "$TARGET" ]; then
        log_err "Número inválido."
        return 1
    fi

    read -rp "Confirma excluir o job '${TARGET}'? (s/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
        log_warn "Cancelado, nada foi removido."
        return 0
    fi

    TMP=$(mktemp)
    awk -v target="$TARGET" '
      /^Job[[:space:]]*{/ { in_job=1; name=""; buf=$0"\n"; next }
      {
        if (in_job) {
          buf = buf $0 "\n"
          if ($0 ~ /Name[[:space:]]*=/ && name=="") { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); name=line }
          if ($0 ~ /^}/) {
            if (name != target) { printf "%s", buf }
            in_job=0; buf=""; name=""
            next
          }
          next
        }
        print
      }
    ' "$DIR_CONF" > "$TMP"
    safe_overwrite "$TMP" "$DIR_CONF"

    if bacula-dir -t -c "$DIR_CONF"; then
        systemctl restart bacula-director
        log_ok "Job '${TARGET}' removido. (O FileSet/Pool/Schedule dele ficaram no arquivo,"
        echo "inofensivos, caso queira reaproveitar - remova manualmente se quiser limpar tudo.)"
    else
        log_err "A remoção quebrou a config. Restaurando backup automático não disponível -"
        log_err "confira /etc/bacula/bacula-dir.conf manualmente."
    fi
}

create_job() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    echo "===================================================="
    echo " Criar novo job de backup"
    echo "===================================================="

    echo "-- Clients existentes --"
    grep -oP '(?<=^Client \{)' -A0 "$DIR_CONF" >/dev/null 2>&1 || true
    grep -A1 '^Client {' "$DIR_CONF" 2>/dev/null | grep -oP '(?<=Name = )\S+' || echo "(nenhum client customizado ainda; o local $(hostname)-fd já existe por padrão)"
    echo ""
    read -rp "Nome do client (ex: $(hostname)-fd, ou nome de um novo): " JOB_CLIENT

    if ! grep -q "Name = ${JOB_CLIENT}$" "$DIR_CONF" 2>/dev/null; then
        log_warn "Client novo, vamos cadastrar."
        read -rp "IP do client: " C_IP
        read -rsp "Senha do client (ENTER pra gerar automática): " C_PASS
        echo ""
        [ -z "$C_PASS" ] && C_PASS=$(openssl rand -base64 24)
        cat >> "$DIR_CONF" <<EOF

Client {
  Name = ${JOB_CLIENT}
  Address = ${C_IP}
  Password = "${C_PASS}"
  Catalog = MyCatalog
  File Retention = 60 days
  Job Retention = 180 days
  TLS Enable = no
  TLS PSK Enable = no
}
EOF
        {
          echo ""
          echo "Client ${JOB_CLIENT} - senha (usar no bacula-fd.conf dele):"
          echo "  ${C_PASS}"
        } >> /root/bacula-install-credentials.txt
        chmod 600 /root/bacula-install-credentials.txt
        log_ok "Client criado. Senha salva em /root/bacula-install-credentials.txt"
    fi

    read -rp "Nome do job (ex: Backup-D-servidor): " JOB_NAME
    [ -n "$JOB_NAME" ] || { log_err "Nome vazio, abortando."; return 1; }
    FS_NAME="${JOB_NAME}-FileSet"

    echo ""
    echo "-- Pastas/drives a incluir no backup (ENTER vazio pra terminar) --"
    INCLUDES=()
    while true; do
        read -rp "Caminho (ex: /mnt/win-dadosbackup ou D:/): " P
        [ -z "$P" ] && break
        INCLUDES+=("$P")
    done
    if [ ${#INCLUDES[@]} -eq 0 ]; then
        log_err "Precisa de ao menos uma pasta. Abortando."
        return 1
    fi

    echo ""
    echo "-- Exclusões (ENTER vazio pra terminar) --"
    EXCLUDES=()
    while true; do
        read -rp "Caminho a excluir (ENTER pra parar): " E
        [ -z "$E" ] && break
        EXCLUDES+=("$E")
    done

    echo ""
    echo "-- Agendamento --"
    echo " 1) Diário, um horário fixo"
    echo " 2) Full no domingo + Incremental nos outros dias"
    echo " 3) Só manual (sem agendamento automático)"
    echo " 4) Customizado (você digita a linha Run do Bacula)"
    read -rp "Escolha: " SCHED_OPT
    SCHED_NAME="${JOB_NAME}-Schedule"
    SCHED_LINES=""
    case "$SCHED_OPT" in
        1)
            read -rp "Horário (ex: 22:00): " HORA
            SCHED_LINES="  Run = Full daily at ${HORA:-22:00}"
            ;;
        2)
            read -rp "Horário (ex: 22:00): " HORA
            HORA=${HORA:-22:00}
            SCHED_LINES="  Run = Full sun at ${HORA}\n  Run = Incremental mon-sat at ${HORA}"
            ;;
        3) SCHED_LINES="" ;;
        4)
            read -rp "Linha Run completa: " CUSTOM
            SCHED_LINES="  ${CUSTOM}"
            ;;
        *) log_warn "Opção inválida, usando 'só manual'."; SCHED_LINES="" ;;
    esac

    echo ""
    read -rp "Retenção dos backups em dias [45]: " RETENTION
    RETENTION=${RETENTION:-45}

    echo ""
    read -rp "Comando a rodar ANTES do backup, no client (ENTER pra pular): " PRE_CMD
    read -rp "Comando a rodar DEPOIS do backup, no client (ENTER pra pular): " POST_CMD

    POOL_NAME="${JOB_NAME}-Pool"
    cat >> "$DIR_CONF" <<EOF

Pool {
  Name = ${POOL_NAME}
  Pool Type = Backup
  Storage = Local-Backup-Storage
  Volume Retention = ${RETENTION} days
  Label Format = "${JOB_NAME}-\${Year}\${Month:p/2/0/r}\${Day:p/2/0/r}-\${NumVols}"
  Recycle = yes
}
EOF

    {
        echo ""
        echo "FileSet {"
        echo "  Name = \"${FS_NAME}\""
        echo "  Include {"
        echo "    Options {"
        echo "      Signature = MD5"
        echo "      Compression = GZIP"
        echo "    }"
        for inc in "${INCLUDES[@]}"; do
            echo "    File = \"${inc}\""
        done
        echo "  }"
        if [ ${#EXCLUDES[@]} -gt 0 ]; then
            echo "  Exclude {"
            for exc in "${EXCLUDES[@]}"; do
                echo "    File = \"${exc}\""
            done
            echo "  }"
        fi
        echo "}"
    } >> "$DIR_CONF"

    SCHED_LINE_FOR_JOB=""
    if [ -n "$SCHED_LINES" ]; then
        printf "\nSchedule {\n  Name = \"%s\"\n%b\n}\n" "$SCHED_NAME" "$SCHED_LINES" >> "$DIR_CONF"
        SCHED_LINE_FOR_JOB="  Schedule = \"${SCHED_NAME}\""
    fi

    PRE_LINE=""
    [ -n "$PRE_CMD" ] && PRE_LINE="  Client Run Before Job = \"${PRE_CMD}\""
    POST_LINE=""
    [ -n "$POST_CMD" ] && POST_LINE="  Client Run After Job = \"${POST_CMD}\""

    cat >> "$DIR_CONF" <<EOF

Job {
  Name = "${JOB_NAME}"
  Type = Backup
  Client = ${JOB_CLIENT}
  FileSet = "${FS_NAME}"
${SCHED_LINE_FOR_JOB}
  Storage = Local-Backup-Storage
  Pool = ${POOL_NAME}
  Messages = Standard
  Priority = 10
${PRE_LINE}
${POST_LINE}
}
EOF

    log_step "Validando e recarregando"
    bacula-dir -t -c /etc/bacula/bacula-dir.conf
    systemctl restart bacula-director

    log_ok "Job '${JOB_NAME}' criado com sucesso."
    echo "Pra rodar agora: sudo bconsole -> run -> ${JOB_NAME}"
}

# ======================================================================
# 10. Listar jobs por client
# ======================================================================
list_jobs_by_client() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    local ROWS
    ROWS=$(awk '
      /^Job[[:space:]]*{/ { in_job=1; name=""; client="" }
      in_job && /Name[[:space:]]*=/ && name=="" { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); name=line }
      in_job && /Client[[:space:]]*=/ { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); client=line }
      /^}/ { if (in_job && name!="") { print client "|" name }; in_job=0; name=""; client="" }
    ' "$DIR_CONF" | sort -t'|' -k1,1)

    echo ""
    echo -e "${BOLD}${CYAN}==================== Jobs configurados ====================${RESET}"
    if [ -z "$ROWS" ]; then
        log_warn "Nenhum job configurado ainda."
        return
    fi

    local LAST_CLIENT=""
    while IFS='|' read -r CLI JOBNAME; do
        [ -z "$CLI" ] && continue
        if [ "$CLI" != "$LAST_CLIENT" ]; then
            echo ""
            echo -e "${BOLD}${YELLOW}Client: ${CLI}${RESET}"
            LAST_CLIENT="$CLI"
        fi
        echo -e "  ${GREEN}•${RESET} ${JOBNAME}"
    done <<< "$ROWS"
    echo ""
}

# ======================================================================
# 11. Listar clients
# ======================================================================
list_clients() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    echo ""
    echo -e "${BOLD}${CYAN}==================== Clients cadastrados ====================${RESET}"
    awk '
      /^Client[[:space:]]*{/ { in_client=1; name=""; addr=""; next }
      in_client && /Name[[:space:]]*=/ { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); name=line }
      in_client && /Address[[:space:]]*=/ { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); addr=line }
      /^}/ { if (in_client && name!="") { print name "|" addr }; in_client=0; name=""; addr="" }
    ' "$DIR_CONF" | while IFS='|' read -r NAME ADDR; do
        echo ""
        echo -e "${BOLD}${YELLOW}${NAME}${RESET}"
        echo -e "   IP: ${ADDR}"
    done
    echo ""
}

# ======================================================================
# 12. Mostrar dados de conexão de um client
# ======================================================================
show_client_info() {
    DIR_CONF="/etc/bacula/bacula-dir.conf"
    read -rp "Nome do client: " CLI
    RESULT=$(awk -v target="$CLI" '
      /^Client[[:space:]]*{/ { in_client=1; name=""; addr=""; pass="" }
      in_client && /Name[[:space:]]*=/ { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); name=line }
      in_client && /Address[[:space:]]*=/ { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); addr=line }
      in_client && /Password[[:space:]]*=/ { line=$0; sub(/^.*=[[:space:]]*/,"",line); gsub(/"/,"",line); pass=line }
      /^}/ { if (in_client && name==target) { print addr "|" pass; exit }; in_client=0 }
    ' "$DIR_CONF" || true)

    ADDR="${RESULT%%|*}"
    PASS="${RESULT##*|}"

    DIR_NAME=$(grep -A2 '^Director {' "$DIR_CONF" | grep -oP '(?<=Name = )\S+' | head -1 || true)
    SERVER_IP=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${BOLD}${CYAN}================ Dados de conexão: ${CLI} ================${RESET}"
    echo -e " ${YELLOW}IP do servidor Bacula:${RESET} ${SERVER_IP}"
    echo -e " ${YELLOW}Nome do Director:${RESET}      ${DIR_NAME}"
    echo -e " ${YELLOW}Nome do client:${RESET}        ${CLI}"
    echo -e " ${YELLOW}IP do client:${RESET}          ${ADDR}"
    echo -e " ${YELLOW}Senha do client:${RESET}       ${PASS}"
    echo -e " ${YELLOW}Porta a liberar (Windows):${RESET} 9102 (entrada, origem ${SERVER_IP})"
    echo -e "${BOLD}${CYAN}=========================================================${RESET}"
}

# ======================================================================
# Menu
# ======================================================================
while true; do
    clear
    show_banner
    echo -e "${BOLD}${CYAN}====================================================${RESET}"
    echo -e "${BOLD}${CYAN}          Bacula - Instalador/Gerenciador${RESET}"
    echo -e "${BOLD}${CYAN}====================================================${RESET}"
    echo -e " ${GREEN}1)${RESET}  Instalação completa (disco + Bacula + PostgreSQL + Bacularis)"
    echo -e " ${GREEN}2)${RESET}  Ativar/configurar OCI"
    echo -e " ${GREEN}3)${RESET}  Reiniciar/validar serviços"
    echo -e " ${GREEN}4)${RESET}  Fixar IP estático do servidor Ubuntu"
    echo -e " ${GREEN}5)${RESET}  Criar novo job de backup (passo a passo)"
    echo -e " ${GREEN}6)${RESET}  Listar jobs configurados (por client)"
    echo -e " ${GREEN}7)${RESET}  Listar clients cadastrados"
    echo -e " ${GREEN}8)${RESET}  Mostrar dados de conexão de um client"
    echo -e " ${GREEN}9)${RESET}  Trocar IP de um client"
    echo -e " ${GREEN}10)${RESET} Adicionar pasta/drive a um job existente"
    echo -e " ${GREEN}11)${RESET} Alterar comando pré-backup de um job existente"
    echo -e " ${GREEN}12)${RESET} Ativar firewall (UFW) e ajustar permissões"
    echo -e " ${GREEN}13)${RESET} Reparar config (remover recursos duplicados)"
    echo -e " ${GREEN}14)${RESET} Instalar Bacularis (WebUI)"
    echo -e " ${GREEN}15)${RESET} Excluir um job (lista e escolhe pelo número)"
    echo -e " ${GREEN}16)${RESET} Configurar alerta de espaço em disco"
    echo -e " ${RED}17)${RESET} Desinstalar tudo (Bacula + Bacularis + banco)"
    echo -e " ${GREEN}18)${RESET} Sair"
    echo -e "${BOLD}${CYAN}====================================================${RESET}"
    read -rp "Escolha uma opção: " OPT
    case "$OPT" in
        1) full_install ;;
        2) configure_oci && restart_services ;;
        3) restart_services ;;
        4) configure_static_ip ;;
        5) create_job ;;
        6) list_jobs_by_client ;;
        7) list_clients ;;
        8) show_client_info ;;
        9) change_client_ip ;;
        10) edit_fileset ;;
        11) edit_prejob_command ;;
        12) harden_server ;;
        13) repair_config ;;
        14) install_bacularis ;;
        15) delete_job ;;
        16) setup_disk_alert ;;
        17) full_purge ;;
        18) echo -e "${CYAN}Até mais.${RESET}"; exit 0 ;;
        *) log_err "Opção inválida." ;;
    esac
    pause
done
