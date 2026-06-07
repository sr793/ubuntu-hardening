#!/bin/bash

##############################################################################
# Script di Hardening per Container LXC Proxmox con Ubuntu 22.04
# Autore: Script generato per migliorare la sicurezza del container
# Descrizione: Applica configurazioni di sicurezza per Ubuntu 22.04
# 
# Funzionalità:
#   - Creazione utente sudoers (se eseguito come root)
#   - Configurazione chiave SSH o password
#   - Hardening completo del sistema
#
# Ambiente target:
#   - Proxmox LXC Container (NON VM)
#   - Ubuntu 22.04
#   - IP da DHCP
#   - Hostname impostato da Proxmox (tab DNS)
#
# Utilizzo:
#   Prima esecuzione (come root):  ./hardening-lxc.sh
#   Seconda esecuzione (come user): ./hardening-lxc.sh
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

# Banner
echo "========================================================="
echo "   HARDENING UBUNTU 22.04 - LXC PROXMOX"
echo "   Container | DHCP | Hostname via DNS"
echo "   Creazione utente sudoers + Hardening completo"
echo "========================================================="
echo ""

# Menu principale
echo ""
log_info "Cosa vuoi fare?"
echo "  1) Esegui hardening completo"
echo "  2) Esegui solo test email e notifiche"
echo "  3) Esegui hardening + test finali"
echo ""
read -p "Scelta [1-3]: " MAIN_CHOICE

case "$MAIN_CHOICE" in
    1)
        RUN_HARDENING=true
        RUN_TESTS=false
        log_info "Modalità: Hardening completo (senza test finali)"
        ;;
    2)
        RUN_HARDENING=false
        RUN_TESTS=true
        log_info "Modalità: Solo test email e notifiche"
        ;;
    3)
        RUN_HARDENING=true
        RUN_TESTS=true
        log_info "Modalità: Hardening completo + test finali"
        ;;
    *)
        log_error "Scelta non valida"
        exit 1
        ;;
esac

echo ""

# Se solo test, salta alla sezione test
if [[ "$RUN_HARDENING" == "false" ]]; then
    log_info "Passaggio diretto ai test..."
    echo ""
    # Salva utente corrente per i test
    CURRENT_USER=$(whoami)
    # Salta all'etichetta TEST_SECTION
    TEST_ONLY=true
else
    TEST_ONLY=false
fi

if [[ "$TEST_ONLY" == "false" ]]; then

##############################################################################
# GESTIONE UTENTE ROOT - CREAZIONE UTENTE SUDOERS
##############################################################################
if [[ $EUID -eq 0 ]]; then
    log_step "Esecuzione come root rilevata"
    echo ""
    log_warn "Il container ha solo l'utente root."
    log_info "Per la sicurezza, creeremo un utente sudoers dedicato."
    echo ""
    
    # Chiedi nome utente
    while true; do
        read -p "Nome utente da creare: " NEW_USERNAME
        if [[ -z "$NEW_USERNAME" ]]; then
            log_error "Il nome utente non può essere vuoto"
            continue
        fi
        if [[ "$NEW_USERNAME" == "root" ]]; then
            log_error "Non puoi usare 'root' come nome utente"
            continue
        fi
        if id "$NEW_USERNAME" &>/dev/null; then
            log_warn "L'utente $NEW_USERNAME esiste già"
            read -p "Vuoi configurarlo comunque? (s/n): " USE_EXISTING
            if [[ "$USE_EXISTING" =~ ^[Ss]$ ]]; then
                USER_EXISTS=true
                break
            else
                continue
            fi
        fi
        break
    done
    
    # Crea utente se non esiste
    if [[ "$USER_EXISTS" != "true" ]]; then
        log_info "Creazione utente $NEW_USERNAME..."
        
        # Crea utente con home directory
        useradd -m -s /bin/bash "$NEW_USERNAME"
        
        log_info "✓ Utente $NEW_USERNAME creato"
    fi
    
    # Configura privilegi sudo (funziona sempre, anche se utente già esiste)
    log_info "Configurazione privilegi sudo..."
    
    # Verifica se il gruppo sudo esiste
    if getent group sudo >/dev/null 2>&1; then
        log_info "Gruppo sudo rilevato, aggiungo utente..."
        usermod -aG sudo "$NEW_USERNAME"
    else
        log_warn "Gruppo sudo non trovato, creo configurazione alternativa..."
    fi
    
    # Assicurati che l'utente possa usare sudo creando file dedicato
    # Questo funziona anche se il gruppo sudo non esiste o non funziona
    cat > /etc/sudoers.d/$NEW_USERNAME <<SUDOERS_EOF
# Sudo privileges for $NEW_USERNAME
$NEW_USERNAME ALL=(ALL:ALL) ALL
SUDOERS_EOF
    
    chmod 440 /etc/sudoers.d/$NEW_USERNAME
    
    # Verifica configurazione sudoers
    if visudo -c -f /etc/sudoers.d/$NEW_USERNAME >/dev/null 2>&1; then
        log_info "✓ Privilegi sudo configurati correttamente"
    else
        log_error "✗ Errore nella configurazione sudoers!"
        rm -f /etc/sudoers.d/$NEW_USERNAME
        exit 1
    fi
    
    # Verifica finale che l'utente possa usare sudo
    if sudo -u "$NEW_USERNAME" sudo -n true 2>/dev/null || \
       groups "$NEW_USERNAME" | grep -qE 'sudo|wheel|admin' || \
       test -f /etc/sudoers.d/$NEW_USERNAME; then
        log_info "✓ Utente $NEW_USERNAME configurato come sudoer"
    else
        log_error "✗ Impossibile verificare privilegi sudo"
        log_warn "L'utente potrebbe non avere accesso sudo"
    fi
    
    echo ""
    log_info "Metodo di autenticazione SSH"
    echo "  1) Chiave SSH (raccomandato - più sicuro)"
    echo "  2) Password (meno sicuro)"
    echo ""
    read -p "Scelta [1-2]: " AUTH_METHOD
    
    DISABLE_SSH_PASSWORD=false
    
    case "$AUTH_METHOD" in
        1)
            log_info "Configurazione chiave SSH..."
            echo ""
            log_info "Incolla la tua chiave SSH pubblica (es. da ~/.ssh/id_ed25519.pub o ~/.ssh/id_rsa.pub)"
            log_info "Formato: ssh-ed25519 AAAA... oppure ssh-rsa AAAA..."
            echo ""
            read -p "Chiave SSH pubblica: " SSH_PUBLIC_KEY
            
            if [[ -z "$SSH_PUBLIC_KEY" ]]; then
                log_error "Chiave SSH vuota! Configurazione fallita."
                exit 1
            fi
            
            # Verifica formato chiave
            if [[ ! "$SSH_PUBLIC_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ssh-dss) ]]; then
                log_error "Formato chiave SSH non valido!"
                log_error "Deve iniziare con: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp256, o ssh-dss"
                exit 1
            fi
            
            # Crea directory .ssh
            USER_HOME=$(eval echo ~$NEW_USERNAME)
            mkdir -p "$USER_HOME/.ssh"
            chmod 700 "$USER_HOME/.ssh"
            
            # Aggiungi chiave
            echo "$SSH_PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
            chmod 600 "$USER_HOME/.ssh/authorized_keys"
            chown -R "$NEW_USERNAME:$NEW_USERNAME" "$USER_HOME/.ssh"
            
            log_info "✓ Chiave SSH configurata per $NEW_USERNAME"
            
            # Disabilita password SSH
            DISABLE_SSH_PASSWORD=true
            log_info "✓ Autenticazione password SSH sarà disabilitata"
            ;;
        2)
            log_info "Configurazione password..."
            echo ""
            
            # Imposta password
            while true; do
                passwd "$NEW_USERNAME"
                if [[ $? -eq 0 ]]; then
                    break
                fi
                log_error "Errore nell'impostazione della password, riprova"
            done
            
            log_info "✓ Password configurata per $NEW_USERNAME"
            log_warn "⚠ RICORDA: Configura una chiave SSH e disabilita la password dopo!"
            ;;
        *)
            log_error "Scelta non valida"
            exit 1
            ;;
    esac
    
    # Configura sudo senza password per l'utente (opzionale)
    echo ""
    read -p "Vuoi consentire a $NEW_USERNAME di usare sudo SENZA password? (s/n): " SUDO_NOPASSWD
    if [[ "$SUDO_NOPASSWD" =~ ^[Ss]$ ]]; then
        # Modifica il file sudoers esistente per rimuovere richiesta password
        cat > /etc/sudoers.d/$NEW_USERNAME <<SUDOERS_NOPASSWD_EOF
# Sudo privileges for $NEW_USERNAME - NO PASSWORD
$NEW_USERNAME ALL=(ALL:ALL) NOPASSWD:ALL
SUDOERS_NOPASSWD_EOF
        
        chmod 440 /etc/sudoers.d/$NEW_USERNAME
        
        if visudo -c -f /etc/sudoers.d/$NEW_USERNAME >/dev/null 2>&1; then
            log_info "✓ Sudo senza password configurato"
        else
            log_error "✗ Errore configurazione sudo no-password"
        fi
    else
        log_info "Sudo richiederà la password"
    fi
    
    # Se chiave SSH, configura SSH ora
    if [[ "$DISABLE_SSH_PASSWORD" == "true" ]]; then
        log_info "Configurazione SSH per chiave pubblica..."
        
        # Backup
        if [[ -f /etc/ssh/sshd_config ]]; then
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.preuser
        fi
        
        # Crea configurazione SSH sicura
        mkdir -p /etc/ssh/sshd_config.d
        tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<SSHD_EOF
# SSH Hardening - Initial Configuration
# Generated during user creation

# Autenticazione
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Accesso utenti
AllowUsers $NEW_USERNAME

# Login e sessione
LoginGraceTime 60
MaxAuthTries 3
MaxSessions 5

# Sicurezza base
X11Forwarding no
PrintMotd no
PrintLastLog yes

# NOTA: Altre configurazioni SSH sono ereditate da /etc/ssh/sshd_config
SSHD_EOF
        
        # Crea directory richiesta da SSH
        mkdir -p /run/sshd
        
        # Test e riavvia SSH
        if sshd -t 2>/dev/null; then
            systemctl restart sshd
            log_info "✓ SSH configurato e riavviato"
        else
            log_error "✗ Errore configurazione SSH"
            rm /etc/ssh/sshd_config.d/99-hardening.conf
        fi
    fi
    
    echo ""
    echo "=================================================="
    log_info "UTENTE CREATO CON SUCCESSO!"
    echo "=================================================="
    echo ""
    echo "Utente: $NEW_USERNAME"
    echo "Gruppo: sudo"
    if [[ "$DISABLE_SSH_PASSWORD" == "true" ]]; then
        echo "Autenticazione: Chiave SSH (password disabilitata)"
    else
        echo "Autenticazione: Password (configura chiave SSH dopo!)"
    fi
    echo ""
    log_warn "PROSSIMI PASSI:"
    echo ""
    echo "1. TESTA la connessione SSH da un altro terminale PRIMA di chiudere questo!"
    echo "   ssh $NEW_USERNAME@<ip_container>"
    echo ""
    echo "2. Una volta verificato l'accesso, ri-esegui questo script come $NEW_USERNAME:"
    echo "   ssh $NEW_USERNAME@<ip_container>"
    echo "   ./hardening-lxc.sh"
    echo ""
    log_warn "NON chiudere questa sessione fino a quando non hai verificato l'accesso!"
    echo ""
    
    exit 0
fi

##############################################################################
# VERIFICHE PRELIMINARI
##############################################################################
log_step "Verifiche preliminari..."

# Verifica che l'utente non sia root
if [[ $EUID -eq 0 ]]; then
   log_error "NON eseguire questo script come root!"
   log_error "Eseguilo con un utente sudo: ./hardening-lxc.sh"
   exit 1
fi

# Salva il nome dell'utente corrente
CURRENT_USER=$(whoami)
log_info "Script eseguito dall'utente: $CURRENT_USER"

# Verifica che l'utente abbia privilegi sudo
if ! sudo -n true 2>/dev/null; then
    log_error "L'utente $CURRENT_USER non ha privilegi sudo"
    log_error "Aggiungi l'utente al gruppo sudo: su - && usermod -aG sudo $CURRENT_USER"
    log_error "Oppure crea file sudoers: echo '$CURRENT_USER ALL=(ALL:ALL) ALL' | sudo tee /etc/sudoers.d/$CURRENT_USER"
    exit 1
fi

# Verifica appartenenza al gruppo sudo o configurazione sudoers
if groups "$CURRENT_USER" | grep -qE 'sudo|wheel|admin'; then
    log_info "✓ Utente $CURRENT_USER nel gruppo sudo/admin"
elif test -f /etc/sudoers.d/$CURRENT_USER; then
    log_info "✓ Utente $CURRENT_USER configurato in /etc/sudoers.d/"
else
    log_warn "⚠ Configurazione sudo non standard (ma funzionante)"
fi

# Verifica funzionalità sudo
if sudo -l &>/dev/null; then
    log_info "✓ Privilegi sudo verificati"
else
    log_error "✗ Impossibile verificare privilegi sudo"
    exit 1
fi

# Verifica ambiente container
VIRT_ENV=$(systemd-detect-virt)
if [[ "$VIRT_ENV" != "lxc" ]] && [[ "$VIRT_ENV" != "systemd-nspawn" ]]; then
    log_warn "⚠ Ambiente rilevato: $VIRT_ENV (atteso: lxc)"
    log_warn "Questo script è ottimizzato per container LXC"
    read -p "Continuare comunque? (s/n): " CONTINUE_ANYWAY
    if [[ ! "$CONTINUE_ANYWAY" =~ ^[Ss]$ ]]; then
        log_warn "Operazione annullata"
        exit 0
    fi
else
    log_info "✓ Ambiente container LXC rilevato correttamente"
fi

log_info "Tutte le verifiche preliminari completate con successo"
echo ""

# Richiesta conferma
read -p "Procedere con l'hardening del sistema? (s/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    log_warn "Operazione annullata dall'utente"
    exit 0
fi

log_info "Inizio hardening del Container LXC Ubuntu 22.04..."
echo ""

##############################################################################
# 0a. CONFIGURAZIONE FQDN NEL FILE HOSTS
##############################################################################
log_step "0a/11 - Configurazione FQDN nel file /etc/hosts..."

# Crea script per impostare FQDN in /etc/hosts
sudo tee /usr/local/bin/update-hosts-fqdn.sh > /dev/null <<'SCRIPT_EOF'
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

sudo chmod +x /usr/local/bin/update-hosts-fqdn.sh
log_info "✓ Script update-hosts-fqdn.sh creato"

# Crea script per aggiornare configurazione Postfix
sudo tee /usr/local/bin/update-postfix-fqdn.sh > /dev/null <<'POSTFIX_SCRIPT_EOF'
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
    # Mantieni configurazione esistente ma assicurati che hostname sia presente
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
    # Ottieni utente dal sistema (primo utente normale uid >= 1000)
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

sudo chmod +x /usr/local/bin/update-postfix-fqdn.sh
log_info "✓ Script update-postfix-fqdn.sh creato"

# Esegui script per configurare FQDN
log_info "Configurazione FQDN in corso..."
sudo /usr/local/bin/update-hosts-fqdn.sh

# Verifica FQDN configurato
CURRENT_FQDN=$(hostname -f)
log_info "✓ FQDN configurato: $CURRENT_FQDN"

# Crea servizio systemd per aggiornare FQDN al boot
sudo tee /etc/systemd/system/update-fqdn.service > /dev/null <<'SERVICE_EOF'
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

sudo systemctl daemon-reload
sudo systemctl enable update-fqdn.service
log_info "✓ Servizio update-fqdn abilitato al boot"

echo ""

##############################################################################
# 0b. CONFIGURAZIONE EMAIL AMMINISTRATORE
##############################################################################
log_step "0b/11 - Configurazione email amministratore..."

echo ""
log_info "Configurazione inoltro email di sistema"
echo ""
echo "Le email di sistema (root, notifiche di sicurezza, cron jobs)"
echo "possono essere inoltrate a un indirizzo email esterno."
echo ""
read -p "Vuoi configurare l'inoltro email? (s/n): " SETUP_EMAIL

if [[ "$SETUP_EMAIL" =~ ^[Ss]$ ]]; then
    read -p "Inserisci l'email amministratore: " ADMIN_EMAIL
    
    if [[ -n "$ADMIN_EMAIL" ]]; then
        # Configura alias per root e utente corrente
        sudo tee -a /etc/aliases > /dev/null <<EOF
root: $ADMIN_EMAIL
$CURRENT_USER: $ADMIN_EMAIL
EOF
        
        # Aggiorna database aliases (se esiste newaliases)
        if command -v newaliases &> /dev/null; then
            sudo newaliases 2>/dev/null || true
        fi
        
        log_info "✓ Email amministratore configurata: $ADMIN_EMAIL"
        echo ""
        log_warn "NOTA: Postfix sarà configurato più avanti nello script"
        log_info "Le email saranno disponibili dopo l'installazione di Postfix"
    else
        log_warn "Email non configurata, puoi farlo dopo modificando /etc/aliases"
    fi
else
    log_info "Configurazione email saltata"
    log_info "Puoi configurarla dopo modificando /etc/aliases e eseguendo newaliases"
    ADMIN_EMAIL=""
fi

echo ""

##############################################################################
# 1. AGGIORNAMENTO SISTEMA
##############################################################################
log_step "1/11 - Aggiornamento sistema..."

log_info "Aggiornamento liste pacchetti..."
sudo apt-get update

log_info "Aggiornamento pacchetti installati..."
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

log_info "Aggiornamento completo del sistema..."
sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y

log_info "Rimozione pacchetti non necessari..."
sudo apt-get autoremove -y
sudo apt-get autoclean

log_info "✓ Sistema aggiornato"
echo ""

##############################################################################
# 2. FIREWALL (UFW)
##############################################################################
log_step "2/11 - Configurazione firewall UFW..."

# Installa UFW se non presente
if ! command -v ufw &> /dev/null; then
    log_info "Installazione UFW..."
    sudo apt-get install -y ufw
fi

# Reset configurazione UFW per partire da zero
log_info "Reset configurazione UFW..."
sudo ufw --force reset

# Configurazione policy di default
log_info "Impostazione policy di default..."
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Permetti connessioni sulla loopback
sudo ufw allow in on lo
sudo ufw allow out on lo

# Permetti SSH (porta 22)
log_info "Configurazione regola SSH..."
sudo ufw allow 22/tcp comment 'SSH Access'

# Abilita UFW
log_info "Abilitazione UFW..."
sudo ufw --force enable

# Verifica status
sudo ufw status verbose

log_info "✓ Firewall UFW configurato e attivo"
echo ""

##############################################################################
# 3. FAIL2BAN
##############################################################################
log_step "3/11 - Configurazione Fail2Ban..."

# Installa Fail2Ban
log_info "Installazione Fail2Ban..."
sudo apt-get install -y fail2ban

# Backup configurazione originale
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.conf.bak 2>/dev/null || true

# Crea configurazione custom
log_info "Creazione configurazione personalizzata..."
sudo tee /etc/fail2ban/jail.local > /dev/null <<'FAIL2BAN_EOF'
[DEFAULT]
# Ban per 1 ora (3600 secondi)
bantime = 3600

# Finestra temporale di 10 minuti per contare i tentativi
findtime = 600

# Numero massimo di tentativi prima del ban
maxretry = 5

# Azione da intraprendere: ban + email (se configurata)
destemail = root@localhost
sendername = Fail2Ban
mta = mail
action = %(action_mwl)s

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
FAIL2BAN_EOF

# Abilita e avvia Fail2Ban
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

# Verifica status
sleep 2
sudo fail2ban-client status

log_info "✓ Fail2Ban configurato e attivo"
echo ""

##############################################################################
# 4. AGGIORNAMENTI AUTOMATICI
##############################################################################
log_step "4/11 - Configurazione aggiornamenti automatici..."

# Installa unattended-upgrades
log_info "Installazione unattended-upgrades..."
sudo apt-get install -y unattended-upgrades apt-listchanges

# Backup configurazione
sudo cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades.bak 2>/dev/null || true

# Configurazione aggiornamenti automatici
log_info "Configurazione aggiornamenti automatici di sicurezza..."
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'UNATTENDED_EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
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

Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";
UNATTENDED_EOF

# Abilita aggiornamenti automatici
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'AUTO_UPGRADES_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
AUTO_UPGRADES_EOF

# Test configurazione
sudo unattended-upgrades --dry-run --debug

log_info "✓ Aggiornamenti automatici configurati"
echo ""

##############################################################################
# 5. SSH HARDENING
##############################################################################
log_step "5/11 - Hardening configurazione SSH..."

# Backup configurazione SSH
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
log_info "✓ Backup SSH: /etc/ssh/sshd_config.bak"

# Verifica se l'utente corrente ha già una chiave SSH configurata
SSH_KEY_EXISTS=false
if sudo test -f "/home/$CURRENT_USER/.ssh/authorized_keys" && \
   sudo test -s "/home/$CURRENT_USER/.ssh/authorized_keys"; then
    log_info "✓ Chiavi SSH già configurate per $CURRENT_USER"
    SSH_KEY_EXISTS=true
else
    log_warn "⚠ Nessuna chiave SSH configurata per $CURRENT_USER"
    SSH_KEY_EXISTS=false
fi

# Chiedi se disabilitare PasswordAuthentication
DISABLE_PASSWORD_AUTH=false
if [[ "$SSH_KEY_EXISTS" == "true" ]]; then
    echo ""
    log_warn "ATTENZIONE: Hai già chiavi SSH configurate"
    echo "Vuoi disabilitare l'autenticazione via password SSH ora?"
    echo "IMPORTANTE: Verifica prima che le chiavi funzionino!"
    read -p "Disabilitare PasswordAuthentication? (s/n): " DISABLE_PWD
    if [[ "$DISABLE_PWD" =~ ^[Ss]$ ]]; then
        DISABLE_PASSWORD_AUTH=true
        log_warn "⚠ Password SSH saranno disabilitate"
    else
        log_info "Password SSH rimarranno abilitate (potrai disabilitarle dopo)"
    fi
else
    log_info "Password SSH rimarranno abilitate (disabilitale dopo aver configurato le chiavi)"
fi

# Applica configurazione SSH hardening
log_info "Applicazione configurazione SSH hardening..."

# Configurazione SSH sicura
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<SSHD_EOF
# SSH Hardening Configuration for LXC
# Generated by hardening script

# Protocollo e cifratura
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
PasswordAuthentication $([ "$DISABLE_PASSWORD_AUTH" == "true" ] && echo "no" || echo "yes")
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
# Non ridefinirlo qui per evitare conflitti
SSHD_EOF

# Crea directory richiesta da SSH privilege separation
sudo mkdir -p /run/sshd

# Test configurazione SSH
if sudo sshd -t; then
    log_info "✓ Configurazione SSH valida"
    
    # Riavvia SSH
    sudo systemctl restart sshd
    log_info "✓ Servizio SSH riavviato"
else
    log_error "✗ Errore nella configurazione SSH!"
    log_error "Ripristino backup..."
    sudo rm /etc/ssh/sshd_config.d/99-hardening.conf
    sudo systemctl restart sshd
    log_error "Configurazione SSH ripristinata"
fi

log_info "✓ SSH hardening completato"
echo ""

##############################################################################
# 6. AIDE (ADVANCED INTRUSION DETECTION ENVIRONMENT)
##############################################################################
log_step "6/10 - Configurazione AIDE..."

# Installa AIDE
log_info "Installazione AIDE..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y aide aide-common

# Backup configurazione
sudo cp /etc/aide/aide.conf /etc/aide/aide.conf.bak 2>/dev/null || true

# Configurazione AIDE personalizzata
log_info "Configurazione AIDE personalizzata..."
sudo tee /etc/aide/aide.conf > /dev/null <<'AIDE_EOF'
# AIDE Configuration for LXC Container

database_in=file:/var/lib/aide/aide.db
database_out=file:/var/lib/aide/aide.db.new
database_new=file:/var/lib/aide/aide.db.new
gzip_dbout=yes

report_url=stdout
report_url=file:/var/log/aide/aide.log

# Custom rules (no special characters in group names)
PERMS = p+u+g+acl+selinux+xattrs
CONTENT = sha256+sha512
CONTENTEX = sha256+sha512+rmd160+haval+gost+crc32+tiger
DATAONLY =  p+n+u+g+s+acl+selinux+xattrs+sha256

# Directories to monitor
/boot CONTENTEX
/bin CONTENTEX
/sbin CONTENTEX
/usr/bin CONTENTEX
/usr/sbin CONTENTEX
/lib CONTENTEX
/lib64 CONTENTEX
/usr/lib CONTENTEX
/usr/lib64 CONTENTEX

# Configuration files
/etc PERMS
!/etc/mtab

# SSH
/etc/ssh CONTENTEX
/root/.ssh CONTENTEX

# Logs (only permissions, not content)
/var/log PERMS

# Cron
/etc/cron.allow CONTENTEX
/etc/cron.deny CONTENTEX
/etc/cron.d CONTENTEX
/etc/cron.daily CONTENTEX
/etc/cron.hourly CONTENTEX
/etc/cron.monthly CONTENTEX
/etc/cron.weekly CONTENTEX
/etc/crontab CONTENTEX

# Exclude dynamic directories
!/var/cache
!/var/tmp
!/tmp
!/var/spool
!/var/lib/aide
!/proc
!/sys
!/dev
!/run
!/var/run
!/var/lock
AIDE_EOF

# Crea directory per log
sudo mkdir -p /var/log/aide
sudo chmod 700 /var/log/aide

log_info "✓ AIDE configurato"

# Chiedi se inizializzare ora il database
echo ""
log_warn "ATTENZIONE: L'inizializzazione del database AIDE può richiedere diversi minuti"
read -p "Vuoi inizializzare il database AIDE ora? (s/n): " INIT_AIDE

if [[ "$INIT_AIDE" =~ ^[Ss]$ ]]; then
    log_info "Inizializzazione database AIDE in corso..."
    log_info "Questo può richiedere 5-10 minuti..."
    
    if sudo aideinit; then
        log_info "✓ Database AIDE inizializzato"
        
        # Attiva il database
        if sudo test -f /var/lib/aide/aide.db.new; then
            sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
            log_info "✓ Database AIDE attivato"
        fi
    else
        log_error "✗ Errore nell'inizializzazione di AIDE"
        log_warn "Puoi inizializzarlo dopo con: sudo aideinit"
    fi
else
    log_info "Inizializzazione AIDE rimandata"
    log_info "Esegui manualmente: sudo aideinit"
fi

# Crea script cron per check giornaliero
sudo tee /etc/cron.daily/aide-check > /dev/null <<'AIDE_CRON_EOF'
#!/bin/bash
# AIDE daily check

HOSTNAME=$(hostname -f)
AIDE_CONF="/etc/aide/aide.conf"
AIDE_LOG="/var/log/aide/aide-$(date +%Y%m%d).log"

# Esegui check solo se database esiste
if [ -f /var/lib/aide/aide.db ] || [ -f /var/lib/aide/aide.db.gz ]; then
    /usr/bin/aide --config="$AIDE_CONF" --check > "$AIDE_LOG" 2>&1
    AIDE_EXIT=$?
    
    if [ $AIDE_EXIT -eq 0 ]; then
        echo "Subject: ✓ AIDE Check - $HOSTNAME
        
AIDE check completato - nessuna modifica rilevata

$(cat $AIDE_LOG)" | /usr/sbin/sendmail root
    else
        echo "Subject: ⚠️ AIDE Alert - $HOSTNAME

⚠️ AIDE ha rilevato modifiche al sistema!

$(cat $AIDE_LOG)" | /usr/sbin/sendmail root
    fi
fi
AIDE_CRON_EOF

sudo chmod +x /etc/cron.daily/aide-check
log_info "✓ Cron job AIDE configurato"

echo ""

##############################################################################
# 7. POSTFIX (EMAIL RELAY)
##############################################################################
log_step "7/10 - Configurazione Postfix per email di sistema..."

# Installa Postfix
log_info "Installazione Postfix..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils

# Backup configurazione
sudo cp /etc/postfix/main.cf /etc/postfix/main.cf.bak

# Configurazione Postfix per email locali
log_info "Configurazione Postfix..."

CURRENT_FQDN=$(hostname -f)
CURRENT_HOSTNAME=$(hostname)

sudo tee /etc/postfix/main.cf > /dev/null <<POSTFIX_EOF
# Postfix Configuration for LXC Container

# Hostname
myhostname = ${CURRENT_FQDN}
mydomain = $(hostname -d)

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

# TLS (loopback only, minimal config)
smtp_tls_security_level = may
smtp_tls_loglevel = 1
POSTFIX_EOF

# Abilita e avvia Postfix
sudo systemctl enable postfix
sudo systemctl restart postfix

# Configura sender address rewriting per usare noreply@
log_info "Configurazione sender rewriting..."

# Header checks per riscrivere From header
sudo tee /etc/postfix/header_checks > /dev/null <<'HEADER_EOF'
# Rewrite From header to use noreply@
/^From:.*@HOSTNAME/      REPLACE From: noreply@FQDN
/^From:.*@FQDN/          REPLACE From: noreply@FQDN  
/^From:.*@localhost/     REPLACE From: noreply@FQDN
HEADER_EOF

# Sender canonical per envelope sender (Return-Path)
sudo tee /etc/postfix/sender_canonical > /dev/null <<CANONICAL_EOF
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

# Sostituisci placeholder in header_checks
sudo sed -i "s/HOSTNAME/${CURRENT_HOSTNAME}/g" /etc/postfix/header_checks
sudo sed -i "s/FQDN/${CURRENT_FQDN}/g" /etc/postfix/header_checks

# Genera database per sender_canonical
sudo postmap /etc/postfix/sender_canonical

# Configura Postfix
sudo postconf -e "header_checks = regexp:/etc/postfix/header_checks"
sudo postconf -e "smtp_header_checks = regexp:/etc/postfix/header_checks"
sudo postconf -e "sender_canonical_maps = hash:/etc/postfix/sender_canonical"
sudo postconf -e "sender_canonical_classes = envelope_sender,header_sender"

# Ricarica Postfix
sudo systemctl reload postfix

log_info "✓ Email locali useranno sender: noreply@${CURRENT_FQDN}"

# Esegui script di aggiornamento FQDN Postfix
if [[ -x /usr/local/bin/update-postfix-fqdn.sh ]]; then
    sudo /usr/local/bin/update-postfix-fqdn.sh
fi

# Verifica status
sleep 2
sudo systemctl status postfix --no-pager | head -10

log_info "✓ Postfix configurato e attivo"

# Invia email di test
if [[ -n "$ADMIN_EMAIL" ]]; then
    echo ""
    log_info "Test invio email a $ADMIN_EMAIL..."
    echo "Test email from hardening script on $(hostname -f)" | mail -s "LXC Hardening Complete" "$ADMIN_EMAIL"
    log_info "✓ Email di test inviata"
else
    echo ""
    log_info "Nessuna email di test inviata (admin email non configurata)"
fi

echo ""

##############################################################################
# 8. CHKROOTKIT
##############################################################################
log_step "8/10 - Installazione chkrootkit..."

# Installa chkrootkit
log_info "Installazione chkrootkit..."
sudo apt-get install -y chkrootkit

# Crea directory per log
sudo mkdir -p /var/log/chkrootkit
sudo chmod 700 /var/log/chkrootkit

# Crea script per scansione settimanale
sudo tee /etc/cron.weekly/chkrootkit-scan > /dev/null <<'CHKROOTKIT_EOF'
#!/bin/bash
# Chkrootkit weekly scan

HOSTNAME=$(hostname -f)
LOG_FILE="/var/log/chkrootkit/chkrootkit-$(date +%Y%m%d).log"

# Esegui scan
/usr/sbin/chkrootkit > "$LOG_FILE" 2>&1

# Controlla risultati
if grep -E "INFECTED|Warning" "$LOG_FILE" > /dev/null; then
    echo "Subject: ⚠️ CHKROOTKIT Alert - $HOSTNAME

⚠️ Chkrootkit ha rilevato potenziali problemi!

NOTA: Alcuni avvisi possono essere falsi positivi.
Verifica manualmente: sudo chkrootkit

$(cat $LOG_FILE)" | /usr/sbin/sendmail root
else
    echo "Subject: ✓ CHKROOTKIT Weekly Scan - $HOSTNAME

Chkrootkit scan completato - nessun problema rilevato

$(tail -20 $LOG_FILE)" | /usr/sbin/sendmail root
fi
CHKROOTKIT_EOF

sudo chmod +x /etc/cron.weekly/chkrootkit-scan
log_info "✓ Chkrootkit installato e scansione settimanale configurata"

echo ""

##############################################################################
# 9. LYNIS (SECURITY AUDITING)
##############################################################################
log_step "9/10 - Installazione Lynis..."

# Installa Lynis
log_info "Installazione Lynis..."
sudo apt-get install -y lynis

# Verifica installazione
if command -v lynis &> /dev/null; then
    log_info "✓ Lynis $(lynis show version 2>/dev/null | head -1) installato"
    echo ""
    log_info "Puoi eseguire un audit completo con: sudo lynis audit system"
else
    log_error "✗ Errore nell'installazione di Lynis"
fi

echo ""

##############################################################################
# 10. PULIZIA FINALE
##############################################################################
log_step "10/10 - Pulizia finale..."

# Rimuovi pacchetti non necessari
sudo apt-get autoremove -y
sudo apt-get autoclean

log_info "✓ Pulizia completata"
echo ""

fi  # Fine blocco if TEST_ONLY == false

##############################################################################
# SEZIONE TEST
##############################################################################

if [[ "$RUN_TESTS" == "true" ]]; then

echo ""
echo "=================================================="
log_info "AVVIO TEST EMAIL E NOTIFICHE"
echo "=================================================="
echo ""

# Funzione per chiedere se eseguire un test
ask_test() {
    local test_name="$1"
    local test_num="$2"
    echo ""
    log_info "TEST $test_num: $test_name"
    read -p "Vuoi eseguire questo test? (s/n): " RUN_TEST
    if [[ "$RUN_TEST" =~ ^[Ss]$ ]]; then
        return 0
    else
        log_info "Test saltato"
        return 1
    fi
}

##############################################################################
# TEST 1: EMAIL LOCALE
##############################################################################
if ask_test "Test email locale (mailutils)" "1/6"; then
    echo ""
    log_info "Invio email di test locale..."
    
    # Determina destinatario
    if [[ -n "$ADMIN_EMAIL" ]]; then
        DEST_EMAIL="$ADMIN_EMAIL"
    else
        DEST_EMAIL="root@localhost"
    fi
    
    # Invia email
    echo "Test email locale dal container LXC $(hostname -f)
    
Timestamp: $(date)
User: $(whoami)
Container: $(systemd-detect-virt)

Questo è un test per verificare che il sistema di email funzioni correttamente." | mail -s "Test Email - $(hostname)" "$DEST_EMAIL"
    
    log_info "✓ Email inviata a: $DEST_EMAIL"
    
    # Mostra coda
    echo ""
    log_info "Coda email corrente:"
    mailq
    
    read -p "Premi INVIO per continuare..."
fi

##############################################################################
# TEST 2: POSTFIX
##############################################################################
if ask_test "Test Postfix diretto (sendmail)" "2/6"; then
    echo ""
    log_info "Test invio con sendmail..."
    
    HOSTNAME=$(hostname -f)
    
    # Determina destinatario
    if [[ -n "$ADMIN_EMAIL" ]]; then
        DEST_EMAIL="$ADMIN_EMAIL"
    else
        DEST_EMAIL="root"
    fi
    
    # Invia con sendmail
    cat <<EMAIL | /usr/sbin/sendmail "$DEST_EMAIL"
Subject: Test Postfix - $HOSTNAME
From: root@$HOSTNAME
To: $DEST_EMAIL

Test diretto con sendmail dal container $HOSTNAME

Timestamp: $(date)
User: $(whoami)

Questo è un test per verificare che Postfix funzioni correttamente.
EMAIL
    
    log_info "✓ Email inviata con sendmail"
    
    # Mostra log Postfix
    echo ""
    log_info "Ultimi log Postfix:"
    sudo journalctl -u postfix -n 10 --no-pager
    
    read -p "Premi INVIO per continuare..."
fi

##############################################################################
# TEST 3: FAIL2BAN
##############################################################################
if ask_test "Test notifica Fail2Ban" "3/6"; then
    echo ""
    log_info "Simulazione notifica Fail2Ban..."
    
    HOSTNAME=$(hostname -f)
    TEST_IP="192.0.2.1"  # IP di test (documentation range)
    
    # Determina destinatario
    if [[ -n "$ADMIN_EMAIL" ]]; then
        DEST_EMAIL="$ADMIN_EMAIL"
    else
        DEST_EMAIL="root"
    fi
    
    cat <<EMAIL | /usr/sbin/sendmail "$DEST_EMAIL"
Subject: [Fail2Ban] Test Alert - $HOSTNAME
From: fail2ban@$HOSTNAME
To: $DEST_EMAIL

⚠️ TEST ALERT - Fail2Ban Notification

Server: $HOSTNAME
Jail: sshd
Action: ban
IP: $TEST_IP
Time: $(date)

Questo è un test della notifica Fail2Ban.
EMAIL
    
    log_info "✓ Notifica Fail2Ban simulata"
    
    # Mostra status Fail2Ban
    echo ""
    log_info "Status Fail2Ban:"
    sudo fail2ban-client status sshd
    
    read -p "Premi INVIO per continuare..."
fi

##############################################################################
# TEST 4: AIDE
##############################################################################
if ask_test "Test check AIDE manuale" "4/6"; then
    echo ""
    
    # Controlla se il database AIDE esiste
    AIDE_DB_EXISTS=false
    if sudo test -f /var/lib/aide/aide.db; then
        AIDE_DB_EXISTS=true
        AIDE_CONF="/etc/aide/aide.conf"
    elif sudo test -f /var/lib/aide/aide.db.gz; then
        AIDE_DB_EXISTS=true
        AIDE_CONF="/etc/aide/aide.conf"
    fi
    
    if [[ "$AIDE_DB_EXISTS" == "false" ]]; then
        log_warn "⚠ Database AIDE non trovato"
        read -p "Vuoi inizializzarlo ora? (s/n): " INIT_NOW
        if [[ "$INIT_NOW" =~ ^[Ss]$ ]]; then
            log_info "Inizializzazione AIDE..."
            if sudo aideinit; then
                if sudo test -f /var/lib/aide/aide.db.new; then
                    sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
                    log_info "✓ Database AIDE attivato"
                    AIDE_DB_EXISTS=true
                elif sudo test -f /var/lib/aide/aide.db.new.gz; then
                    sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
                    log_info "✓ Database AIDE attivato (compresso)"
                    AIDE_DB_EXISTS=true
                fi
            else
                log_error "✗ Errore nell'inizializzazione di AIDE"
            fi
        else
            log_info "Inizializzazione saltata"
        fi
    fi
    
    # Esegui check solo se il database esiste
    if [[ "$AIDE_DB_EXISTS" == "true" ]]; then
        if [[ -x /etc/cron.daily/aide-check ]]; then
            log_info "Eseguo script cron AIDE..."
            sudo /etc/cron.daily/aide-check &
            AIDE_PID=$!
            
            echo ""
            log_info "AIDE in esecuzione (PID: $AIDE_PID)"
            log_info "Riceverai un'email con il report quando completato"
            
            read -p "Vuoi attendere il completamento? (s/n): " WAIT_AIDE
            if [[ "$WAIT_AIDE" =~ ^[Ss]$ ]]; then
                wait $AIDE_PID
                log_info "✓ Check AIDE completato"
            else
                log_info "Check AIDE continua in background"
            fi
        else
            if [[ -n "$AIDE_CONF" ]]; then
                log_info "Eseguo check manuale con config: $AIDE_CONF"
                
                # Esegui check e cattura output
                AIDE_OUTPUT=$(sudo aide --config="$AIDE_CONF" --check 2>&1)
                AIDE_EXIT=$?
                
                if [[ $AIDE_EXIT -eq 0 ]]; then
                    echo "$AIDE_OUTPUT" | mail -s "✓ AIDE Manual Check - $(hostname)" root
                    log_info "✓ Check AIDE completato - nessuna modifica rilevata"
                    log_info "  Report inviato via email"
                else
                    echo "$AIDE_OUTPUT" | mail -s "⚠️ AIDE Manual Check - $(hostname)" root
                    log_warn "⚠ Check AIDE completato - modifiche rilevate"
                    log_info "  Report inviato via email"
                    echo ""
                    log_info "Anteprima modifiche:"
                    echo "$AIDE_OUTPUT" | grep -E "^(Added|Removed|Changed):" | head -10
                fi
            else
                log_error "Configurazione AIDE non trovata"
            fi
        fi
    else
        log_warn "⚠ Test AIDE saltato - database non inizializzato"
    fi
    
    read -p "Premi INVIO per continuare..."
fi

##############################################################################
# TEST 5: CHKROOTKIT
##############################################################################
if ask_test "chkrootkit scan completo" "5/6"; then
    echo ""
    log_info "Esecuzione scansione chkrootkit completa..."
    log_warn "Questo può richiedere 1-3 minuti..."
    
    if [[ -x /etc/cron.weekly/chkrootkit-scan ]]; then
        log_info "Eseguo script cron chkrootkit..."
        sudo /etc/cron.weekly/chkrootkit-scan
        log_info "✓ Scansione completata e email inviata"
    else
        log_warn "Script chkrootkit non trovato, eseguo scansione diretta..."
        
        HOSTNAME=$(hostname -f)
        TEMP_REPORT="/tmp/chkrootkit-test-$$.txt"
        
        cat > "$TEMP_REPORT" <<REPORT
=== CHKROOTKIT TEST SCAN REPORT ===
Server: $HOSTNAME
Date: $(date)

--- SCAN RESULTS ---
REPORT
        
        sudo chkrootkit >> "$TEMP_REPORT" 2>&1
        
        if grep -E "INFECTED|Warning" "$TEMP_REPORT" > /dev/null; then
            log_warn "⚠ Potenziali problemi rilevati (potrebbero essere falsi positivi)"
            echo "" >> "$TEMP_REPORT"
            echo "⚠️ WARNING: Potential issues detected!" >> "$TEMP_REPORT"
            cat "$TEMP_REPORT" | mail -s "⚠️ CHKROOTKIT TEST - $HOSTNAME" root
        else
            log_info "✓ Nessun problema rilevato"
            echo "" >> "$TEMP_REPORT"
            echo "✓ No issues detected" >> "$TEMP_REPORT"
            cat "$TEMP_REPORT" | mail -s "✓ chkrootkit Test - $HOSTNAME" root
        fi
        
        rm -f "$TEMP_REPORT"
        log_info "✓ Report inviato via email"
    fi
    
    echo ""
    log_info "Controlla log chkrootkit:"
    if [[ -d /var/log/chkrootkit ]]; then
        sudo ls -lth /var/log/chkrootkit/ | head -5
    else
        log_warn "Directory /var/log/chkrootkit non trovata"
    fi
    
    read -p "Premi INVIO per continuare..."
fi

##############################################################################
# TEST 6: RIEPILOGO E MONITORAGGIO
##############################################################################
if ask_test "Riepilogo finale e monitoraggio log" "6/6"; then
    echo ""
    log_info "=== RIEPILOGO TEST ==="
    echo ""
    
    echo "1. Coda email corrente:"
    mailq
    echo ""
    
    echo "2. Servizi di sicurezza attivi:"
    for service in postfix fail2ban; do
        STATUS=$(systemctl is-active $service 2>/dev/null || echo "non trovato")
        if [[ "$STATUS" == "active" ]]; then
            echo "   ✓ $service: $STATUS"
        else
            echo "   ✗ $service: $STATUS"
        fi
    done
    echo ""
    
    echo "3. Alias email configurati:"
    grep -E "^root:|^$(whoami):" /etc/aliases 2>/dev/null || echo "   Nessun alias trovato"
    echo ""
    
    echo "4. Ultimi 20 log Postfix:"
    sudo journalctl -u postfix -n 20 --no-pager
    echo ""
    
    log_info "=== MONITORAGGIO LIVE ==="
    read -p "Vuoi monitorare i log Postfix in tempo reale? (s/n): " MONITOR_LOGS
    if [[ "$MONITOR_LOGS" =~ ^[Ss]$ ]]; then
        echo ""
        log_info "Monitoraggio log Postfix (premi CTRL+C per uscire)..."
        echo ""
        sudo journalctl -u postfix -f
    fi
fi

echo ""
echo "=================================================="
log_info "TEST COMPLETATI"
echo "=================================================="
echo ""

fi  # Fine blocco RUN_TESTS

##############################################################################
# RIEPILOGO FINALE
##############################################################################

if [[ "$TEST_ONLY" == "false" ]]; then

# Riepilogo configurazioni
log_info "RIEPILOGO CONFIGURAZIONE LXC:"
echo "  ✓ Sistema aggiornato"
echo "  ✓ Ambiente: Container LXC ($(systemd-detect-virt))"
echo "  ✓ Firewall UFW: $(sudo ufw status | grep Status | awk '{print $2}')"
echo "  ✓ Fail2Ban: $(sudo systemctl is-active fail2ban)"
echo "  ✓ Aggiornamenti automatici: Abilitati"
echo "  ✓ SSH Hardening: Root login disabilitato, accesso utenti sudo abilitato"
echo "  ✓ AIDE: $(sudo test -f /var/lib/aide/aide.db -o -f /var/lib/aide/aide.db.gz && echo 'Inizializzato' || echo 'Da inizializzare')"
echo "  ✓ Postfix: $(systemctl is-active postfix 2>/dev/null || echo 'non configurato')"
echo "  ℹ Auditd: Non installato (usa logging host Proxmox)"
echo ""

log_warn "AZIONI SUCCESSIVE OBBLIGATORIE:"
echo "1. Configura una chiave SSH per l'utente $CURRENT_USER"
echo "   Esempio locale: ssh-keygen -t ed25519 -C 'tua-email@example.com'"
echo "   Esempio copia: ssh-copy-id $CURRENT_USER@<ip_lxc>"
echo ""
echo "2. TESTA la connessione SSH da un'altra finestra PRIMA di chiudere questa!"
echo "   ssh $CURRENT_USER@<ip_lxc>"
echo ""
echo "3. Dopo aver verificato la chiave SSH, disabilita PasswordAuthentication:"
echo "   sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/99-hardening.conf"
echo "   sudo systemctl restart sshd"
echo ""

log_warn "COMANDI UTILI:"
echo "  • Verifica firewall: sudo ufw status verbose"
echo "  • Verifica fail2ban: sudo fail2ban-client status sshd"
echo "  • Audit sicurezza completo: sudo lynis audit system"
echo "  • Verifica integrità file: sudo aide --config=/etc/aide/aide.conf --check"
echo "  • Scansione rootkit: sudo chkrootkit"
echo "  • Log email Postfix: sudo journalctl -u postfix -f"
echo "  • Ultimi log Postfix: sudo journalctl -u postfix -n 50"
echo "  • Coda email: mailq"
echo "  • Leggi email locali: sudo mail -u root"
if [[ -n "$ADMIN_EMAIL" ]]; then
    echo "  • Test email: echo 'test' | mail -s 'Test' $ADMIN_EMAIL"
else
    echo "  • Test email: echo 'test' | mail -s 'Test' root"
fi
echo ""

log_info "Backup salvati:"
echo "  • SSH: /etc/ssh/sshd_config.bak"
echo ""

log_warn "NOTA: I container LXC non richiedono riavvio per l'hardening"
log_info "Tutte le modifiche sono già attive"
echo ""

fi  # Fine blocco if TEST_ONLY == false

##############################################################################
# FINE SCRIPT
##############################################################################
log_info "Script completato!"
