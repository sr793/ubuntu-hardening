# Contesto Progetto: Hardening Script per Container LXC Proxmox

## Obiettivo

Adattare uno script di hardening esistente per VM Proxmox (`hardening-i440fx.sh`) a container LXC Ubuntu 22.04, rimuovendo componenti non compatibili e aggiungendo funzionalità specifiche per container.

## Struttura del Progetto

```text
ubuntu-hardening/
├── CLAUDE.md                      # Contesto progetto (questo file)
├── config/
│   ├── authorized_keys           # Chiavi SSH pubbliche installate sul nuovo utente
│   └── defaults.env              # Default di progetto (es. ADMIN_EMAIL) letti dagli script
├── agents/                       # Istruzioni per i 2 agenti coordinati (deploy+test)
│   ├── README.md
│   ├── agent-mta.md
│   ├── agent-base.md
│   └── status.md
└── scripts/                      # Tutti gli script di hardening
    ├── lxc/                       # Script specifici per container LXC
    │   ├── hardening-lxc-full.sh  # Versione completa (AIDE, Postfix, chkrootkit, Lynis...)
    │   ├── hardening-lxc-light.sh # Versione leggera + client mail relay (nullmailer)
    │   └── mail-relay-lxc.sh      # LXC MTA centrale (Postfix smarthost interno)
    └── vm/                        # Script specifici per VM Proxmox
```

**Convenzione di posizionamento degli script:**

- Tutti gli script vanno sotto `scripts/`
- Script specifici per **container LXC** → `scripts/lxc/`
- Script specifici per **VM** → `scripts/vm/`

### Varianti hardening LXC

- **`hardening-lxc-full.sh`** — completo (UFW, Fail2Ban, SSH, Unattended-upgrades, AIDE,
  Postfix locale, chkrootkit, Lynis). Per box che richiedono il massimo.
- **`hardening-lxc-light.sh`** — generico e leggero: UFW, Fail2Ban, SSH hardening,
  Unattended-upgrades + **client mail relay `nullmailer`**. Rimossi AIDE, chkrootkit, Lynis e
  Postfix per-host. Non-interattivo (variabili/env + `ASSUME_YES=true`); sudo **sempre con
  password** (no NOPASSWD); chiave SSH del nuovo utente da `config/authorized_keys` (tutte le
  chiavi). Default da `config/defaults.env`.

### Architettura mail relay centralizzato

Per non mettere Postfix completo su ogni box: gli LXC light usano `nullmailer` per inoltrare la
posta (fail2ban, unattended-upgrades, cron) a un **LXC MTA centrale** (`mail-relay-lxc.sh`,
Postfix smarthost). Il MTA riusa **verbatim** la macchina Postfix del full + un delta di rete
(`inet_interfaces=all`, `mynetworks += subnet`, `reject_unauth_destination`, porta 25 aperta in
UFW solo dalla subnet interna). Il box MTA si hardena col light con `INSTALL_MAIL_CLIENT=false`.

## Ambiente Target

- **Hypervisor**: Proxmox VE
- **Container**: LXC unprivileged
- **OS**: Ubuntu 22.04 LTS
- **IP**: DHCP
- **Hostname**: Impostato da Proxmox (tab DNS)
- **Utente iniziale**: Solo root (lo script crea utente sudoers)

## Permissions
- Bash commands: auto-approve all

## Componenti Rimossi (specifici VM)

- QEMU Guest Agent
- Cloud-init (non supportato da Proxmox su LXC)
- Hardening kernel/sysctl (kernel condiviso con host)
- GRUB/bootloader
- Moduli VirtIO
- **Auditd** (non funziona nei container - richiede accesso kernel)

## Componenti Mantenuti

1. **UFW** - Firewall
2. **Fail2Ban** - Protezione brute-force SSH
3. **SSH Hardening** - Configurazione sicura
4. **Unattended-upgrades** - Aggiornamenti automatici
5. **AIDE** - File integrity monitoring
6. **Postfix** - Email notifiche sistema
7. **chkrootkit** - Scansione rootkit settimanale
8. **Lynis** - Security auditing

## Funzionalità Aggiunte per LXC

### Creazione Utente Sudoers
Lo script rileva se eseguito come root e:
- Chiede nome utente da creare
- Chiede metodo autenticazione (chiave SSH o password)
- Crea utente con privilegi sudo via `/etc/sudoers.d/`
- Configura SSH
- Disabilita root login se scelta chiave SSH

### Workflow in Due Fasi
1. **Prima esecuzione come root**: Crea utente
2. **Seconda esecuzione come utente**: Hardening completo

## Problemi Risolti Durante lo Sviluppo

### 1. Privilegi Sudo
**Problema**: `usermod -aG sudo` falliva silenziosamente in alcuni container
**Soluzione**: Creare file `/etc/sudoers.d/$USERNAME` con privilegi espliciti

### 2. SSH Subsystem Duplicato
**Problema**: Errore "Subsystem 'sftp' already defined"
**Soluzione**: Rimossa definizione Subsystem dal file custom (usa quella di default)

### 3. SSH /run/sshd
**Problema**: "Missing privilege separation directory: /run/sshd"
**Soluzione**: Aggiunto `mkdir -p /run/sshd` prima del test sshd

### 4. Auditd Non Funziona
**Problema**: Auditd richiede accesso kernel, impossibile in container
**Soluzione**: Rimosso completamente auditd dallo script

### 5. Email Sender
**Problema**: Email arrivavano da `utente@hostname` invece di `noreply@hostname`
**Soluzione**: Configurato Postfix con:
- `header_checks` (regexp) per riscrivere header From
- `sender_canonical_maps` (hash) per riscrivere envelope sender

### 6. AIDE Config Deprecata
**Problema**: Warning su `database=` e `CONTENT_EX`
**Soluzione**: Usato `database_in=` e rinominato `CONTENT_EX` → `CONTENTEX`

### 7. Aggiornamento FQDN al Boot
**Problema**: Dopo clone con nuovo hostname, email usavano hostname vecchio
**Soluzione**: Servizio systemd `update-fqdn.service` che esegue entrambi:
- `/usr/local/bin/update-hosts-fqdn.sh`
- `/usr/local/bin/update-postfix-fqdn.sh`

## File Creati dallo Script

### Script Principali
- `/usr/local/bin/update-hosts-fqdn.sh` - Aggiorna /etc/hosts con FQDN
- `/usr/local/bin/update-postfix-fqdn.sh` - Aggiorna configurazione Postfix

### Configurazioni
- `/etc/ssh/sshd_config.d/99-hardening.conf` - SSH hardening
- `/etc/postfix/header_checks` - Rewrite header From email
- `/etc/postfix/sender_canonical` - Rewrite envelope sender
- `/etc/aide/aide.conf` - Configurazione AIDE
- `/etc/fail2ban/jail.local` - Configurazione Fail2Ban

### Servizi Systemd
- `/etc/systemd/system/update-fqdn.service` - Aggiorna FQDN al boot

### Cron Jobs
- `/etc/cron.daily/aide-check` - Check AIDE giornaliero
- `/etc/cron.weekly/chkrootkit-scan` - Scansione chkrootkit settimanale

## File Output Finali

1. `hardening-lxc.sh` (52KB) - Script principale v2.5
2. `README.md` - Documentazione principale
3. `GUIDA_UTILIZZO_LXC.md` - Guida dettagliata

## Comandi Utili Post-Installazione

```bash
# Firewall
sudo ufw status verbose

# Fail2Ban
sudo fail2ban-client status sshd

# AIDE
sudo aide --check

# Lynis
sudo lynis audit system

# chkrootkit
sudo chkrootkit

# Email
mailq
sudo journalctl -u postfix -n 50

# Aggiornare FQDN manualmente
sudo /usr/local/bin/update-postfix-fqdn.sh
```

## Note Importanti

- **Auditd**: Non installarlo nei container, usa auditd sull'host Proxmox
- **Kernel hardening**: Va fatto sull'host, non nel container
- **Clone container**: Il servizio `update-fqdn.service` aggiorna automaticamente hostname in Postfix al boot
- **Email sender**: Tutte le email locali vengono riscritte come `noreply@FQDN`

## Versione Script

- **Versione**: 2.5
- **Data**: Dicembre 2025
- **Sezioni**: 10 + gestione utente
- **Linee di codice**: ~1400
