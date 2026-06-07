#!/bin/bash

##############################################################################
# Setup LXC MTA centrale (Postfix smarthost interno) per Proxmox / Ubuntu 22.04
#
# Riceve la posta inoltrata dagli LXC "light" (via nullmailer) e la instrada
# verso la destinazione finale.
#
# RIUSA VERBATIM la macchina Postfix collaudata di hardening-lxc-full.sh
# (main.cf, header_checks, sender_canonical, script FQDN, update-fqdn.service)
# e aggiunge SOLO il delta di rete necessario per fare da relay:
#   - inet_interfaces = all
#   - mynetworks += subnet interna
#   - smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination
#   - relayhost = $UPSTREAM_RELAY (se valorizzato)
#
# Prerequisito: eseguire prima hardening-lxc-light.sh con INSTALL_MAIL_CLIENT=false.
#
# Esecuzione non-interattiva: valorizzare le variabili sotto + ASSUME_YES=true.
##############################################################################

set -e

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

##############################################################################
# CONFIGURAZIONE (override via variabili d'ambiente)
##############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="${DEFAULTS_FILE:-$SCRIPT_DIR/../../config/defaults.env}"
if [[ -f "$DEFAULTS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$DEFAULTS_FILE"
fi

# Subnet interna autorizzata a inoltrare la posta (es. 192.168.14.0/24)
INTERNAL_NET="${INTERNAL_NET:-}"
# Smarthost a monte (es. [smtp.example.com]:587). Vuoto = consegna diretta via MX.
UPSTREAM_RELAY="${UPSTREAM_RELAY:-}"
# Destinatario alert (default da config/defaults.env)
ADMIN_EMAIL="${ADMIN_EMAIL:-root}"

ASSUME_YES="${ASSUME_YES:-false}"

# Prefisso privilegi (funziona sia come root sia come sudoer)
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

confirm() {
    local prompt="$1"
    if [[ "$ASSUME_YES" == "true" ]]; then return 0; fi
    read -r -p "$prompt (s/n): " _ans
    [[ "$_ans" =~ ^[Ss]$ ]]
}

echo "========================================================="
echo "   LXC MTA CENTRALE (Postfix smarthost interno)"
echo "========================================================="
echo ""

if [[ -z "$INTERNAL_NET" ]]; then
    log_error "INTERNAL_NET non impostato (subnet interna autorizzata, es. 192.168.14.0/24)"
    exit 1
fi
log_info "Subnet interna autorizzata: $INTERNAL_NET"
log_info "Destinatario alert: $ADMIN_EMAIL"
[[ -n "$UPSTREAM_RELAY" ]] && log_info "Smarthost a monte: $UPSTREAM_RELAY" || log_info "Consegna: diretta via MX"
echo ""
if ! confirm "Procedere con la configurazione del MTA?"; then
    log_warn "Operazione annullata"
    exit 0
fi
echo ""

##############################################################################
# 1. SCRIPT FQDN (verbatim dal full) + servizio update-fqdn
##############################################################################
log_step "1/4 - Script FQDN (hosts + Postfix)..."

# --- update-hosts-fqdn.sh (verbatim full) ---
$SUDO tee /usr/local/bin/update-hosts-fqdn.sh > /dev/null <<'SCRIPT_EOF'
#!/bin/bash
# Script per aggiornare /etc/hosts con FQDN dal DNS

# Ottieni hostname
HOSTNAME=$(hostname)

# Ottieni dominio da resolv.conf
DOMAIN=$(grep -m1 '^search\s' /etc/resolv.conf | awk '{print $2}')

# Se non c'è 'search', prova con 'domain'
if [[ -z "$DOMAIN" ]]; then
    DOMAIN=$(grep -m1 '^domain\s' /etc/resolv.conf | awk '{print $2}')
fi

# Se ancora non c'è dominio, usa hostname -d come fallback
if [[ -z "$DOMAIN" ]]; then
    DOMAIN=$(hostname -d 2>/dev/null)
fi

# Se abbiamo un dominio, costruisci FQDN
if [[ -n "$DOMAIN" ]]; then
    FQDN="${HOSTNAME}.${DOMAIN}"

    # Backup hosts
    cp /etc/hosts /etc/hosts.bak

    # Rimuovi vecchie entry per questo hostname
    sed -i "/\s${HOSTNAME}\s/d" /etc/hosts
    sed -i "/\s${HOSTNAME}$/d" /etc/hosts
    sed -i "/\s${FQDN}\s/d" /etc/hosts
    sed -i "/\s${FQDN}$/d" /etc/hosts

    # Ottieni IP principale (escludendo loopback)
    PRIMARY_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n1)

    # Se non c'è IP esterno, usa loopback
    if [[ -z "$PRIMARY_IP" ]]; then
        PRIMARY_IP="127.0.1.1"
    fi

    # Aggiungi entry con FQDN
    echo "${PRIMARY_IP}    ${FQDN} ${HOSTNAME}" >> /etc/hosts

    # Assicurati che localhost sia presente
    if ! grep -q "^127.0.0.1\s" /etc/hosts; then
        sed -i '1i127.0.0.1    localhost' /etc/hosts
    fi

    if ! grep -q "^::1\s" /etc/hosts; then
        echo "::1    localhost ip6-localhost ip6-loopback" >> /etc/hosts
    fi

    logger -t update-hosts-fqdn "FQDN aggiornato: ${FQDN} (${PRIMARY_IP})"
    echo "FQDN configurato: ${FQDN}"
else
    logger -t update-hosts-fqdn "Nessun dominio trovato in resolv.conf"
    echo "Attenzione: nessun dominio trovato"
fi
SCRIPT_EOF
$SUDO chmod +x /usr/local/bin/update-hosts-fqdn.sh

# --- update-postfix-fqdn.sh (verbatim full) ---
$SUDO tee /usr/local/bin/update-postfix-fqdn.sh > /dev/null <<'POSTFIX_SCRIPT_EOF'
#!/bin/bash
# Script per aggiornare configurazione Postfix con FQDN corrente

# Verifica che postfix sia installato
if ! command -v postfix &> /dev/null; then
    logger -t update-postfix-fqdn "Postfix non installato, skip"
    exit 0
fi

# Verifica che esista il file di configurazione
if [[ ! -f /etc/postfix/main.cf ]]; then
    logger -t update-postfix-fqdn "File /etc/postfix/main.cf non trovato"
    exit 1
fi

# Ottieni FQDN corrente
CURRENT_FQDN=$(hostname -f)
CURRENT_HOSTNAME=$(hostname)

# Backup configurazione
cp /etc/postfix/main.cf /etc/postfix/main.cf.bak

# Aggiorna myhostname
if grep -q "^myhostname\s*=" /etc/postfix/main.cf; then
    sed -i "s/^myhostname\s*=.*/myhostname = ${CURRENT_FQDN}/" /etc/postfix/main.cf
else
    echo "myhostname = ${CURRENT_FQDN}" >> /etc/postfix/main.cf
fi

# Aggiorna mydestination se necessario
if grep -q "^mydestination\s*=" /etc/postfix/main.cf; then
    if ! grep "^mydestination" /etc/postfix/main.cf | grep -q "$CURRENT_FQDN"; then
        sed -i "s/^mydestination\s*=\s*\(.*\)/mydestination = \1, ${CURRENT_FQDN}, ${CURRENT_HOSTNAME}/" /etc/postfix/main.cf
    fi
fi

# Aggiorna header_checks se esiste
if [[ -f /etc/postfix/header_checks ]]; then
    cat > /etc/postfix/header_checks <<EOF
# Rewrite From header to use noreply@
/^From:.*@${CURRENT_HOSTNAME}/      REPLACE From: noreply@${CURRENT_FQDN}
/^From:.*@${CURRENT_FQDN}/          REPLACE From: noreply@${CURRENT_FQDN}
/^From:.*@localhost/     REPLACE From: noreply@${CURRENT_FQDN}
EOF
    logger -t update-postfix-fqdn "header_checks aggiornato"
fi

# Aggiorna sender_canonical se esiste
if [[ -f /etc/postfix/sender_canonical ]]; then
    SYSTEM_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')

    cat > /etc/postfix/sender_canonical <<EOF
root                           noreply@${CURRENT_FQDN}
${SYSTEM_USER}                 noreply@${CURRENT_FQDN}
root@${CURRENT_HOSTNAME}       noreply@${CURRENT_FQDN}
root@${CURRENT_FQDN}           noreply@${CURRENT_FQDN}
root@localhost                 noreply@${CURRENT_FQDN}
${SYSTEM_USER}@${CURRENT_HOSTNAME}  noreply@${CURRENT_FQDN}
${SYSTEM_USER}@${CURRENT_FQDN}      noreply@${CURRENT_FQDN}
${SYSTEM_USER}@localhost            noreply@${CURRENT_FQDN}
fail2ban@${CURRENT_HOSTNAME}   noreply@${CURRENT_FQDN}
fail2ban@${CURRENT_FQDN}       noreply@${CURRENT_FQDN}
EOF
    postmap /etc/postfix/sender_canonical
    logger -t update-postfix-fqdn "sender_canonical aggiornato"
fi

# Ricarica Postfix
systemctl reload postfix

logger -t update-postfix-fqdn "Postfix aggiornato con FQDN: ${CURRENT_FQDN}"
echo "Postfix configurato con FQDN: ${CURRENT_FQDN}"
POSTFIX_SCRIPT_EOF
$SUDO chmod +x /usr/local/bin/update-postfix-fqdn.sh

# Configura FQDN in /etc/hosts ora
$SUDO /usr/local/bin/update-hosts-fqdn.sh || true
log_info "✓ Script FQDN creati"
echo ""

##############################################################################
# 2. POSTFIX (config verbatim dal full)
##############################################################################
log_step "2/4 - Installazione e configurazione Postfix..."
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils

$SUDO cp /etc/postfix/main.cf /etc/postfix/main.cf.bak 2>/dev/null || true

CURRENT_FQDN=$(hostname -f 2>/dev/null || hostname)
CURRENT_HOSTNAME=$(hostname)
CURRENT_USER="${SUDO_USER:-$(whoami)}"

# main.cf VERBATIM dal full (loopback-only: il delta di rete è applicato dopo)
$SUDO tee /etc/postfix/main.cf > /dev/null <<POSTFIX_EOF
# Postfix Configuration for LXC Container

# Hostname
myhostname = ${CURRENT_FQDN}
mydomain = $(hostname -d 2>/dev/null)

# Network
inet_interfaces = loopback-only
inet_protocols = ipv4

# Mail delivery
mydestination = \$myhostname, localhost.\$mydomain, localhost, ${CURRENT_HOSTNAME}
mynetworks = 127.0.0.0/8 [::1]/128
relay_domains =
relayhost =

# Mailbox
home_mailbox = Maildir/
mailbox_size_limit = 0
recipient_delimiter = +

# Compatibility
compatibility_level = 2

# Security
smtpd_banner = \$myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no

# TLS (minimal config)
smtp_tls_security_level = may
smtp_tls_loglevel = 1
POSTFIX_EOF

$SUDO systemctl enable postfix
$SUDO systemctl restart postfix

# Sender rewriting noreply@ (verbatim dal full)
$SUDO tee /etc/postfix/header_checks > /dev/null <<'HEADER_EOF'
# Rewrite From header to use noreply@
/^From:.*@HOSTNAME/      REPLACE From: noreply@FQDN
/^From:.*@FQDN/          REPLACE From: noreply@FQDN
/^From:.*@localhost/     REPLACE From: noreply@FQDN
HEADER_EOF

$SUDO tee /etc/postfix/sender_canonical > /dev/null <<CANONICAL_EOF
root                           noreply@${CURRENT_FQDN}
${CURRENT_USER}                noreply@${CURRENT_FQDN}
root@${CURRENT_HOSTNAME}       noreply@${CURRENT_FQDN}
root@${CURRENT_FQDN}           noreply@${CURRENT_FQDN}
root@localhost                 noreply@${CURRENT_FQDN}
${CURRENT_USER}@${CURRENT_HOSTNAME}  noreply@${CURRENT_FQDN}
${CURRENT_USER}@${CURRENT_FQDN}      noreply@${CURRENT_FQDN}
${CURRENT_USER}@localhost            noreply@${CURRENT_FQDN}
fail2ban@${CURRENT_HOSTNAME}   noreply@${CURRENT_FQDN}
fail2ban@${CURRENT_FQDN}       noreply@${CURRENT_FQDN}
CANONICAL_EOF

$SUDO sed -i "s/HOSTNAME/${CURRENT_HOSTNAME}/g" /etc/postfix/header_checks
$SUDO sed -i "s/FQDN/${CURRENT_FQDN}/g" /etc/postfix/header_checks
$SUDO postmap /etc/postfix/sender_canonical
$SUDO postconf -e "header_checks = regexp:/etc/postfix/header_checks"
$SUDO postconf -e "smtp_header_checks = regexp:/etc/postfix/header_checks"
$SUDO postconf -e "sender_canonical_maps = hash:/etc/postfix/sender_canonical"
$SUDO postconf -e "sender_canonical_classes = envelope_sender,header_sender"
$SUDO systemctl reload postfix
log_info "✓ Postfix base (verbatim full) configurato"
echo ""

##############################################################################
# 3. DELTA DI RETE: da loopback-only a relay (via postconf -e)
##############################################################################
log_step "3/4 - Delta di rete (relay)..."
$SUDO postconf -e "inet_interfaces = all"
$SUDO postconf -e "mynetworks = 127.0.0.0/8 [::1]/128, ${INTERNAL_NET}"
$SUDO postconf -e "smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination"
if [[ -n "$UPSTREAM_RELAY" ]]; then
    $SUDO postconf -e "relayhost = ${UPSTREAM_RELAY}"
    log_info "✓ Smarthost a monte: $UPSTREAM_RELAY"
else
    $SUDO postconf -e "relayhost ="
    log_info "✓ Consegna diretta via MX (nessun smarthost)"
fi

# Servizio systemd per aggiornare FQDN al boot (verbatim full)
$SUDO tee /etc/systemd/system/update-fqdn.service > /dev/null <<'SERVICE_EOF'
[Unit]
Description=Update FQDN in /etc/hosts and Postfix from DNS
After=network.target
Before=postfix.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-hosts-fqdn.sh
ExecStart=/usr/local/bin/update-postfix-fqdn.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF
$SUDO systemctl daemon-reload
$SUDO systemctl enable update-fqdn.service

# Rigenera header_checks/sender_canonical col FQDN corrente e ricarica
$SUDO /usr/local/bin/update-postfix-fqdn.sh || true
$SUDO systemctl restart postfix
log_info "✓ Relay di rete attivo (mynetworks: $INTERNAL_NET)"
echo ""

##############################################################################
# 4. FIREWALL: porta 25 solo dalla subnet interna
##############################################################################
log_step "4/4 - UFW: SMTP (25) solo dalla subnet interna..."
if ! command -v ufw &> /dev/null; then
    $SUDO apt-get install -y ufw
fi
$SUDO ufw allow from "$INTERNAL_NET" to any port 25 proto tcp comment 'SMTP relay interno'
$SUDO ufw reload 2>/dev/null || true
log_info "✓ UFW: 25/tcp consentito da $INTERNAL_NET"
echo ""

##############################################################################
# RIEPILOGO
##############################################################################
echo "========================================================="
log_info "MTA CENTRALE CONFIGURATO"
echo "========================================================="
echo ""
log_info "Configurazione effettiva (postconf -n):"
$SUDO postconf -n | grep -E '^(myhostname|inet_interfaces|mynetworks|relayhost|smtpd_recipient_restrictions)' || true
echo ""
log_info "Verifiche utili:"
echo "  $SUDO postconf -n"
echo "  $SUDO tail -f /var/log/mail.log"
echo "  mailq    # coda"
echo "  # test ricezione da un light: deve comparire status=sent in mail.log"
echo ""
