# Agenti coordinati — test deploy hardening LXC

Due agenti, **uno per macchina**, ciascuno crea/valida e **testa sulla macchina reale** via SSH.
Coordinamento tramite questo folder + `status.md` (board condivisa).

## Macchine (target SOLO per la sessione di test corrente)

| Ruolo | IP             | File istruzioni  | Script principale            |
|-------|----------------|------------------|------------------------------|
| MTA   | 192.168.14.20  | `agent-mta.md`   | `mail-relay-lxc.sh`          |
| BASE  | 192.168.14.21  | `agent-base.md`  | `hardening-lxc-light.sh`     |

- Subnet interna relay: `192.168.14.0/24`
- Accesso: `root@<ip>` via chiave SSH dalla macchina di sviluppo (già funzionante).
- ⚠️ Gli IP sono **session-only**: non vanno scritti negli script, solo passati come variabili.

## Parametri condivisi (env passati agli script)

```
NEW_USERNAME=simone
DISABLE_SSH_PASSWORD=true          # accesso SSH solo a chiave
ASSUME_YES=true                    # esecuzione non-interattiva
ADMIN_EMAIL=alert@simoneradaelli.it  # (default già in config/defaults.env)
NEW_USER_PASSWORD=<chiesta a inizio sessione, NON committare>
```

- sudo richiede **sempre** la password (nessun NOPASSWD). L'agente usa la password per
  `chpasswd` (fase root) e per pilotare i `sudo` in modo non-interattivo.
- Le chiavi SSH stanno in `config/authorized_keys` (installate tutte sul nuovo utente).

### Sudo non-interattivo (metodo verificato)

⚠️ Il solo priming `echo "$PASS" | sudo -S -v` **NON basta**: i `sudo` interni agli script girano
senza tty e tornano a chiedere la password. Metodo che funziona — helper `SUDO_ASKPASS` + `sudo -A`:

```sh
# sul remoto, come l'utente sudoer (es. simone)
cat > ~/.sudohelper <<'EOF'
#!/bin/sh
cat /home/simone/.sudopw
EOF
chmod 700 ~/.sudohelper
printf '%s' "$PASS" > ~/.sudopw && chmod 600 ~/.sudopw
export SUDO_ASKPASS="$HOME/.sudohelper"
# poi eseguire lo script: ogni `sudo` cade su askpass quando non ha credenziali in cache
# (se serve, sostituire `sudo` con `sudo -A`, oppure pre-cache: `sudo -A -v`)
# A FINE SESSIONE: shred -u ~/.sudopw ~/.sudohelper
```

Pulire SEMPRE `~/.sudopw` / `~/.sudohelper` al termine (contengono la password).

## Ordine e handshake (vedi `status.md`)

1. **Fase 0 (orchestratore)**: file di progetto già pronti (`config/`, script, `agents/`).
   Quando lo script light è validato → `LIGHT_READY`.
2. **MTA** e **BASE** procedono sulle rispettive macchine.
   - BASE: fase root (crea utente `simone`) → fase utente (hardening light, `RELAY_HOST=192.168.14.20`).
   - MTA: fase root (crea utente) → light con `INSTALL_MAIL_CLIENT=false` → `mail-relay-lxc.sh`
     con `INTERNAL_NET=192.168.14.0/24`. Al termine → `MTA_READY`.
3. **E2E mail**: quando `MTA_READY`, BASE invia una mail di test e si verifica l'arrivo sul MTA
   (vedi criteri in `agent-base.md` / `agent-mta.md`).
4. Ogni agente annota esiti e problemi in `status.md`.

## Anti-lockout

Durante i restart di SSH/UFW mantenere SEMPRE una sessione `root` aperta sulla macchina
(non affidarsi solo alla sessione utente in corso). Testare `sshd -t` prima di ogni restart.

## Deploy del repo sulla macchina

```
rsync -az --delete \
  --exclude '.git' \
  /percorso/ubuntu-hardening/ root@<ip>:/root/ubuntu-hardening/
```
Poi eseguire gli script da `/root/ubuntu-hardening/scripts/lxc/` (così `SCRIPT_DIR` risolve
`../../config/authorized_keys` e `../../config/defaults.env`).
