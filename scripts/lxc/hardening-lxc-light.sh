#!/bin/bash

##############################################################################
# Script di Hardening LIGHT per Container LXC Proxmox con Ubuntu 22.04
#
# Variante generica e leggera per piccoli LXC monoservizio.
# Mantiene SOLO l'hardening essenziale:
#   - Creazione utente sudoers (se eseguito come root)
#   - Aggiornamento sistema
#   - Client mail relay (nullmailer)  [opzionale]
#   - UFW (firewall)
#   - Fail2Ban
#   - Unattended-upgrades
#   - SSH hardening
#
# Rimossi rispetto al full: AIDE, Postfix completo, chkrootkit, Lynis,
# gestione FQDN/hosts, sezione test email.
#
# Le notifiche email vengono inoltrate a un MTA centrale (relay) tramite
# nullmailer; vedi RELAY_HOST.
#
# Esecuzione non-interattiva (per automazione/agenti): valorizzare le
# variabili d'ambiente sotto + ASSUME_YES=true. In assenza, lo script
# chiede i valori mancanti (uso manuale).
#
# Ambiente target: Proxmox LXC (Ubuntu 22.04), IP DHCP, hostname via DNS.
#
# Utilizzo:
#   Prima esecuzione (root):   ./hardening-lxc-light.sh   -> crea utente
#   Seconda esecuzione (user): ./hardening-lxc-light.sh   -> hardening
##############################################################################

set -e

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

##############################################################################
# CONFIGURAZIONE (override via variabili d'ambiente)
##############################################################################

# Directory dello script (per risolvere i file di progetto)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default di progetto (valori non segreti, es. ADMIN_EMAIL)
DEFAULTS_FILE="${DEFAULTS_FILE:-$SCRIPT_DIR/../../config/defaults.env}"
if [[ -f "$DEFAULTS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$DEFAULTS_FILE"
fi

# Utente da creare (fase root)
NEW_USERNAME="${NEW_USERNAME:-}"
# Password dell'utente (NON committare; usata con chpasswd). Se vuota in modalità
# interattiva verrà chiesta con passwd.
NEW_USER_PASSWORD="${NEW_USER_PASSWORD:-}"
# File con le chiavi SSH pubbliche da installare (TUTTE le righe valide)
SSH_KEYS_FILE="${SSH_KEYS_FILE:-$SCRIPT_DIR/../../config/authorized_keys}"
# Accesso SSH solo a chiave (disabilita PasswordAuthentication)
DISABLE_SSH_PASSWORD="${DISABLE_SSH_PASSWORD:-true}"

# Relay mail centrale (MTA). Se vuoto, il client nullmailer viene saltato.
RELAY_HOST="${RELAY_HOST:-}"
# Destinatario notifiche (default da config/defaults.env, fallback root)
ADMIN_EMAIL="${ADMIN_EMAIL:-root}"
# Installa il client mail relay (nullmailer). false sul box che FA da MTA.
INSTALL_MAIL_CLIENT="${INSTALL_MAIL_CLIENT:-true}"

# Modalità non-interattiva: salta le conferme e fallisce se manca un dato richiesto
ASSUME_YES="${ASSUME_YES:-false}"

# Helper conferma (rispetta ASSUME_YES)
confirm() {
    local prompt="$1"
    if [[ "$ASSUME_YES" == "true" ]]; then
        return 0
    fi
    read -r -p "$prompt (s/n): " _ans
    [[ "$_ans" =~ ^[Ss]$ ]]
}

# Banner
echo "========================================================="
echo "   HARDENING LIGHT UBUNTU 22.04 - LXC PROXMOX"
echo "   Container | DHCP | Hostname via DNS"
echo "   UFW + Fail2Ban + SSH + Unattended-upgrades + nullmailer"
echo "========================================================="
echo ""

##############################################################################
# GESTIONE UTENTE ROOT - CREAZIONE UTENTE SUDOERS
##############################################################################
if [[ $EUID -eq 0 ]]; then
    log_step "Esecuzione come root rilevata: creazione utente sudoers"
    echo ""

    # Nome utente
    if [[ -z "$NEW_USERNAME" ]]; then
        if [[ "$ASSUME_YES" == "true" ]]; then
            log_error "NEW_USERNAME non impostato (modalità non-interattiva)"
            exit 1
        fi
        while true; do
            read -r -p "Nome utente da creare: " NEW_USERNAME
            [[ -n "$NEW_USERNAME" && "$NEW_USERNAME" != "root" ]] && break
            log_error "Nome utente non valido"
        done
    fi
    if [[ "$NEW_USERNAME" == "root" ]]; then
        log_error "Non puoi usare 'root' come nome utente"
        exit 1
    fi

    # Crea utente se non esiste
    if id "$NEW_USERNAME" &>/dev/null; then
        log_warn "L'utente $NEW_USERNAME esiste già, lo configuro comunque"
    else
        log_info "Creazione utente $NEW_USERNAME..."
        useradd -m -s /bin/bash "$NEW_USERNAME"
        log_info "✓ Utente $NEW_USERNAME creato"
    fi

    # Privilegi sudo (CON password: nessuna opzione NOPASSWD)
    log_info "Configurazione privilegi sudo (con password)..."
    if getent group sudo >/dev/null 2>&1; then
        usermod -aG sudo "$NEW_USERNAME"
    fi
    cat > "/etc/sudoers.d/$NEW_USERNAME" <<SUDOERS_EOF
# Sudo privileges for $NEW_USERNAME
$NEW_USERNAME ALL=(ALL:ALL) ALL
SUDOERS_EOF
    chmod 440 "/etc/sudoers.d/$NEW_USERNAME"
    if visudo -c -f "/etc/sudoers.d/$NEW_USERNAME" >/dev/null 2>&1; then
        log_info "✓ Privilegi sudo configurati"
    else
        log_error "✗ Errore nella configurazione sudoers!"
        rm -f "/etc/sudoers.d/$NEW_USERNAME"
        exit 1
    fi

    # Installa TUTTE le chiavi pubbliche dal file di progetto
    log_info "Installazione chiavi SSH da: $SSH_KEYS_FILE"
    if [[ ! -s "$SSH_KEYS_FILE" ]]; then
        log_error "File chiavi mancante o vuoto: $SSH_KEYS_FILE"
        log_error "Popola config/authorized_keys con almeno una chiave pubblica."
        exit 1
    fi
    # Valida che ci sia almeno una chiave (riga non vuota e non commento)
    if ! grep -qE '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-)' "$SSH_KEYS_FILE"; then
        log_error "Nessuna chiave SSH valida trovata in $SSH_KEYS_FILE"
        exit 1
    fi
    USER_HOME=$(eval echo "~$NEW_USERNAME")
    mkdir -p "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    # Copia l'intero file (multi-riga = più chiavi autorizzate)
    install -m 600 "$SSH_KEYS_FILE" "$USER_HOME/.ssh/authorized_keys"
    chown -R "$NEW_USERNAME:$NEW_USERNAME" "$USER_HOME/.ssh"
    NUM_KEYS=$(grep -cE '^[[:space:]]*(ssh-|ecdsa-)' "$USER_HOME/.ssh/authorized_keys")
    log_info "✓ Installate $NUM_KEYS chiave/i per $NEW_USERNAME"

    # Imposta password utente (necessaria per sudo)
    if [[ -n "$NEW_USER_PASSWORD" ]]; then
        echo "$NEW_USERNAME:$NEW_USER_PASSWORD" | chpasswd
        log_info "✓ Password impostata per $NEW_USERNAME"
    elif [[ "$ASSUME_YES" == "true" ]]; then
        log_warn "⚠ NEW_USER_PASSWORD non fornita: nessuna password impostata (sudo non utilizzabile finché non la imposti)"
    else
        log_info "Imposta la password per $NEW_USERNAME:"
        passwd "$NEW_USERNAME"
    fi

    # Configurazione SSH iniziale (accesso a chiave, root disabilitato)
    log_info "Configurazione SSH iniziale..."
    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.preuser
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<SSHD_EOF
# SSH Hardening - Initial Configuration (light)
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication $([ "$DISABLE_SSH_PASSWORD" == "true" ] && echo "no" || echo "yes")
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
AllowUsers $NEW_USERNAME
LoginGraceTime 60
MaxAuthTries 3
MaxSessions 5
X11Forwarding no
PrintMotd no
PrintLastLog yes
SSHD_EOF

    mkdir -p /run/sshd
    if sshd -t 2>/dev/null; then
        systemctl restart ssh
        log_info "✓ SSH configurato e riavviato"
    else
        log_error "✗ Errore configurazione SSH, rimuovo override"
        rm -f /etc/ssh/sshd_config.d/99-hardening.conf
        systemctl restart ssh || true
    fi

    echo ""
    echo "=================================================="
    log_info "UTENTE $NEW_USERNAME CREATO"
    echo "=================================================="
    echo ""
    echo "PROSSIMI PASSI:"
    echo "1. Verifica l'accesso SSH a chiave da un altro terminale:"
    echo "   ssh $NEW_USERNAME@<ip_container>"
    echo "2. Poi ri-esegui questo script come $NEW_USERNAME per l'hardening."
    echo ""
    log_warn "NON chiudere questa sessione root finché non hai verificato l'accesso!"
    exit 0
fi

##############################################################################
# VERIFICHE PRELIMINARI (esecuzione come utente)
##############################################################################
log_step "Verifiche preliminari..."

CURRENT_USER=$(whoami)
log_info "Script eseguito dall'utente: $CURRENT_USER"

if ! sudo -n true 2>/dev/null; then
    # In modalità non-interattiva i sudo successivi useranno -S/askpass: verifichiamo
    # solo che l'utente sia un sudoer noto.
    if ! sudo -l &>/dev/null && [[ "$ASSUME_YES" != "true" ]]; then
        log_error "L'utente $CURRENT_USER non ha privilegi sudo"
        exit 1
    fi
fi

if groups "$CURRENT_USER" | grep -qE 'sudo|wheel|admin'; then
    log_info "✓ Utente $CURRENT_USER nel gruppo sudo/admin"
elif test -f "/etc/sudoers.d/$CURRENT_USER"; then
    log_info "✓ Utente $CURRENT_USER configurato in /etc/sudoers.d/"
else
    log_warn "⚠ Configurazione sudo non standard"
fi

VIRT_ENV=$(systemd-detect-virt || echo "unknown")
if [[ "$VIRT_ENV" != "lxc" ]] && [[ "$VIRT_ENV" != "systemd-nspawn" ]]; then
    log_warn "⚠ Ambiente rilevato: $VIRT_ENV (atteso: lxc)"
    if ! confirm "Continuare comunque?"; then
        log_warn "Operazione annullata"
        exit 0
    fi
else
    log_info "✓ Ambiente container LXC rilevato"
fi

if ! confirm "Procedere con l'hardening LIGHT del sistema?"; then
    log_warn "Operazione annullata dall'utente"
    exit 0
fi
log_info "Inizio hardening LIGHT..."
echo ""

##############################################################################
# 1. AGGIORNAMENTO SISTEMA
##############################################################################
log_step "1/6 - Aggiornamento sistema..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
sudo apt-get autoremove -y
sudo apt-get autoclean
log_info "✓ Sistema aggiornato"
echo ""

##############################################################################
# 2. CLIENT MAIL RELAY (nullmailer)
##############################################################################
log_step "2/6 - Client mail relay (nullmailer)..."
if [[ "$INSTALL_MAIL_CLIENT" != "true" ]]; then
    log_info "INSTALL_MAIL_CLIENT=false: salto nullmailer (questo box è il relay/MTA)"
elif [[ -z "$RELAY_HOST" ]]; then
    log_warn "RELAY_HOST non impostato: salto nullmailer (le notifiche resteranno locali)"
else
    log_info "Installazione nullmailer + bsd-mailx..."
    # nullmailer per primo: soddisfa il virtual package mail-transport-agent
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nullmailer
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y bsd-mailx

    log_info "Configurazione nullmailer (relay: $RELAY_HOST)..."
    # Config statica (non dipende dall'hostname)
    echo "$RELAY_HOST smtp --port=25" | sudo tee /etc/nullmailer/remotes >/dev/null
    sudo chmod 600 /etc/nullmailer/remotes
    # Inoltra tutta la posta locale (root/utenti) all'indirizzo admin
    echo "$ADMIN_EMAIL" | sudo tee /etc/nullmailer/adminaddr >/dev/null

    # Script che riallinea l'identità mail (mittente/Message-ID/HELO) all'FQDN corrente.
    # Serve perché dopo un cambio hostname / clone i file restano col nome vecchio
    # (es. From: root@<host-vecchio> mentre il Subject mostra quello nuovo).
    sudo tee /usr/local/bin/update-nullmailer-fqdn.sh > /dev/null <<'NM_FQDN_EOF'
#!/bin/bash
# Riallinea l'identità di nullmailer all'FQDN corrente
if ! dpkg -s nullmailer >/dev/null 2>&1; then
    logger -t update-nullmailer-fqdn "nullmailer non installato, skip"
    exit 0
fi
FQDN=$(hostname -f 2>/dev/null || hostname)
DOMAIN=$(hostname -d 2>/dev/null)
echo "$FQDN" > /etc/mailname
echo "$FQDN" > /etc/nullmailer/me
echo "$FQDN" > /etc/nullmailer/defaulthost
[ -n "$DOMAIN" ] && echo "$DOMAIN" > /etc/nullmailer/defaultdomain
# try-restart: riavvia solo se già attivo (al boot gira PRIMA di nullmailer → no-op)
systemctl try-restart nullmailer 2>/dev/null || true
logger -t update-nullmailer-fqdn "identita nullmailer -> ${FQDN}"
echo "nullmailer identity: ${FQDN}"
NM_FQDN_EOF
    sudo chmod +x /usr/local/bin/update-nullmailer-fqdn.sh

    # Servizio systemd: riallinea l'identità al boot (gestisce clone / cambio hostname)
    sudo tee /etc/systemd/system/update-nullmailer-fqdn.service > /dev/null <<'NM_SVC_EOF'
[Unit]
Description=Update nullmailer identity (mailname/me/defaulthost) from current FQDN
After=network-online.target
Wants=network-online.target
# DEVE girare PRIMA di nullmailer e fail2ban: l'identità va corretta prima che
# vengano inviate notifiche (es. la mail "sshd started" di fail2ban al boot).
Before=nullmailer.service fail2ban.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-nullmailer-fqdn.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
NM_SVC_EOF
    sudo systemctl daemon-reload
    sudo systemctl enable update-nullmailer-fqdn.service

    # Applica subito l'identità corrente e (ri)avvia nullmailer
    sudo /usr/local/bin/update-nullmailer-fqdn.sh
    sudo systemctl enable nullmailer
    sudo systemctl restart nullmailer
    log_info "✓ nullmailer verso $RELAY_HOST (admin: $ADMIN_EMAIL); identità auto-allineata al boot"
fi
echo ""

##############################################################################
# 3. FIREWALL (UFW)
##############################################################################
log_step "3/6 - Configurazione firewall UFW..."
if ! command -v ufw &> /dev/null; then
    sudo apt-get install -y ufw
fi
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on lo
sudo ufw allow out on lo
# Unica porta in ingresso: SSH. Per aprire altre porte di servizio in futuro:
#   sudo ufw allow <porta>/tcp comment '<descrizione>'
sudo ufw allow 22/tcp comment 'SSH Access'
sudo ufw --force enable
sudo ufw status verbose
log_info "✓ Firewall UFW attivo (solo SSH)"
echo ""

##############################################################################
# 4. FAIL2BAN
##############################################################################
log_step "4/6 - Configurazione Fail2Ban..."
sudo apt-get install -y fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.conf.bak 2>/dev/null || true

FQDN=$(hostname -f 2>/dev/null || hostname)
sudo tee /etc/fail2ban/jail.local > /dev/null <<FAIL2BAN_EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

# Notifiche email (via relay/nullmailer). action_mw = ban + email con whois.
destemail = $ADMIN_EMAIL
sender = fail2ban@$FQDN
mta = mail
action = %(action_mw)s

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
FAIL2BAN_EOF

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban
sleep 2
sudo fail2ban-client status || true
log_info "✓ Fail2Ban configurato e attivo"
echo ""

##############################################################################
# 5. AGGIORNAMENTI AUTOMATICI
##############################################################################
log_step "5/6 - Configurazione aggiornamenti automatici..."
sudo apt-get install -y unattended-upgrades apt-listchanges
sudo cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades.bak 2>/dev/null || true

sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<UNATTENDED_EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};

Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";

Unattended-Upgrade::Mail "$ADMIN_EMAIL";
Unattended-Upgrade::MailReport "on-change";
UNATTENDED_EOF

sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<AUTO_UPGRADES_EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
AUTO_UPGRADES_EOF

sudo unattended-upgrades --dry-run --debug || true
log_info "✓ Aggiornamenti automatici configurati"
echo ""

##############################################################################
# 6. SSH HARDENING
##############################################################################
log_step "6/6 - Hardening configurazione SSH..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
log_info "✓ Backup SSH: /etc/ssh/sshd_config.bak"

sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<SSHD_EOF
# SSH Hardening Configuration for LXC (light)
# Generated by hardening-lxc-light.sh

# Protocollo e host key
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Cifrari moderni
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256

# Autenticazione
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication $([ "$DISABLE_SSH_PASSWORD" == "true" ] && echo "no" || echo "yes")
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Accesso utenti
AllowUsers $CURRENT_USER

# Login e sessione
LoginGraceTime 60
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2

# Sicurezza aggiuntiva
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
PermitUserEnvironment no
Compression no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no

# Banner e logging
Banner none
SyslogFacility AUTH
LogLevel VERBOSE

# NOTA: Subsystem sftp è già definito in /etc/ssh/sshd_config
SSHD_EOF

sudo mkdir -p /run/sshd
if sudo sshd -t; then
    log_info "✓ Configurazione SSH valida"
    sudo systemctl restart ssh
    log_info "✓ Servizio SSH riavviato"
else
    log_error "✗ Errore nella configurazione SSH! Ripristino..."
    sudo rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    sudo systemctl restart ssh
fi
log_info "✓ SSH hardening completato"
echo ""

##############################################################################
# PULIZIA FINALE
##############################################################################
log_step "Pulizia finale..."
sudo apt-get autoremove -y
sudo apt-get autoclean
log_info "✓ Pulizia completata"
echo ""

##############################################################################
# RIEPILOGO
##############################################################################
echo "========================================================="
log_info "HARDENING LIGHT COMPLETATO"
echo "========================================================="
echo ""
log_info "Stato servizi:"
sudo ufw status | head -1 || true
sudo systemctl is-active ssh && echo "  ssh: active" || true
sudo systemctl is-active fail2ban && echo "  fail2ban: active" || true
if [[ "$INSTALL_MAIL_CLIENT" == "true" && -n "$RELAY_HOST" ]]; then
    sudo systemctl is-active nullmailer && echo "  nullmailer: active" || true
fi
echo ""
log_info "Verifiche utili:"
echo "  sudo ufw status verbose"
echo "  sudo fail2ban-client status sshd"
echo "  echo test | mail -s prova $ADMIN_EMAIL   # test notifica"
echo ""
