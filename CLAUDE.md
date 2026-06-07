# Contesto Progetto: Hardening Script per Container LXC Proxmox

## Obiettivo

Script di hardening per container **LXC Ubuntu 22.04** su Proxmox (derivati da uno script per VM,
`hardening-i440fx.sh`). Due varianti LXC — **full** e **light** — più un **LXC MTA centrale** per
le notifiche email.

## Struttura del Progetto

```text
ubuntu-hardening/
├── CLAUDE.md                      # Contesto progetto (questo file)
├── TODO.md                        # Attività aperte
├── config/
│   ├── authorized_keys           # Chiavi SSH pubbliche installate sul nuovo utente
│   └── defaults.env              # Default di progetto (es. ADMIN_EMAIL) letti dagli script
├── agents/                       # Istruzioni per i 2 agenti coordinati (deploy+test)
│   ├── README.md
│   ├── agent-mta.md
│   ├── agent-base.md
│   └── status.md
└── scripts/
    ├── lxc/
    │   ├── hardening-lxc-full.sh  # Variante completa
    │   ├── hardening-lxc-light.sh # Variante leggera + client mail relay (nullmailer)
    │   └── mail-relay-lxc.sh      # LXC MTA centrale (Postfix smarthost interno)
    └── vm/                        # (vuoto) script specifici per VM
```

Convenzione: script LXC in `scripts/lxc/`, script VM in `scripts/vm/`.

## Varianti hardening LXC

| Componente            | full | light |
|-----------------------|:----:|:-----:|
| UFW (firewall)        |  ✓   |   ✓   |
| Fail2Ban              |  ✓   |   ✓   |
| SSH hardening         |  ✓   |   ✓   |
| Unattended-upgrades   |  ✓   |   ✓   |
| Email                 | Postfix locale | nullmailer → MTA centrale |
| AIDE                  |  ✓   |   ✗   |
| chkrootkit            |  ✓   |   ✗   |
| Lynis                 |  ✓   |   ✗   |

**Specificità del light** (oltre alla rimozione di AIDE/chkrootkit/Lynis/Postfix-per-host):
- Non-interattivo: input da variabili/env + `ASSUME_YES=true` (per automazione/agenti).
- Chiave SSH del nuovo utente da `config/authorized_keys` (installa **tutte** le chiavi).
- sudo **sempre con password** (nessun NOPASSWD).
- Default letti da `config/defaults.env` (es. `ADMIN_EMAIL`).
- `INSTALL_MAIL_CLIENT=false` → salta nullmailer (usato sul box che fa da MTA).

## Architettura mail relay centralizzato

Gli LXC light usano **`nullmailer`** per inoltrare la posta (fail2ban, unattended-upgrades, cron)
a un **LXC MTA centrale** (`mail-relay-lxc.sh`, Postfix smarthost). Il MTA riusa **verbatim** la
macchina Postfix del full + un delta di rete (`inet_interfaces=all`, `mynetworks += subnet`,
`reject_unauth_destination`, porta 25 in UFW solo dalla subnet interna). Il box MTA si hardena col
light con `INSTALL_MAIL_CLIENT=false`.

## Ambiente Target

- **Hypervisor**: Proxmox VE — **Container**: LXC unprivileged
- **OS**: Ubuntu 22.04 LTS — **IP**: DHCP — **Hostname**: da Proxmox (tab DNS)
- **Utente iniziale**: solo root (lo script crea l'utente sudoers)

## Escluso dai container (va sull'host Proxmox)

QEMU Guest Agent, Cloud-init, GRUB/bootloader, moduli VirtIO. Inoltre **Auditd** e
**kernel/sysctl hardening** richiedono il kernel (condiviso con l'host) → vanno fatti **sull'host**,
non nel container (vedi [TODO.md](TODO.md)).

## Creazione utente sudoers (fase root)

Eseguito come root, lo script: chiede/legge il nome utente, lo crea, gli dà sudo via
`/etc/sudoers.d/$USER` (con password), installa le chiavi da `config/authorized_keys`, configura
SSH (root login off, accesso a chiave) ed esce. La **seconda esecuzione** come utente fa
l'hardening vero e proprio.

## Note tecniche / gotcha

- **Sudo**: privilegi via `/etc/sudoers.d/` (a volte `usermod -aG sudo` non basta nei container).
- **SSH**: non ridefinire `Subsystem sftp` (già nel default); `mkdir -p /run/sshd` prima di `sshd -t`.
- **Email (full / MTA)**: mittente riscritto a `noreply@FQDN` via `header_checks` +
  `sender_canonical`; `update-fqdn.service` riallinea hostname/Postfix al boot (utile dopo clone).
- **Identità mail nel light**: nullmailer scrive mittente/Message-ID/HELO da `/etc/mailname` +
  `me`/`defaulthost`/`defaultdomain`. Dopo cambio hostname/clone restano col nome vecchio →
  `update-nullmailer-fqdn.sh` + `update-nullmailer-fqdn.service` li riallineano al boot.
- **Light non-interattivo**: i `sudo` interni girano senza tty → per l'automazione usare
  `SUDO_ASKPASS` (vedi `agents/README.md`), non il solo `sudo -S -v`.

## Comandi utili post-installazione

```bash
sudo ufw status verbose                 # firewall
sudo fail2ban-client status sshd        # fail2ban
mailq                                    # coda mail (light: nullmailer / MTA: postfix)
# Solo full: sudo aide --check | sudo lynis audit system | sudo chkrootkit
```

## TODO

Attività aperte tracciate in [TODO.md](TODO.md) (es. hardening host Proxmox).
