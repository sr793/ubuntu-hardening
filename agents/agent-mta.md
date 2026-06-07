# Agente MTA — 192.168.14.20

> ✅ ESEGUITO (2026-06-07): MTA configurato, relay attivo, no open-relay, mail locale `status=sent`.
> Esiti in `status.md`. Questa scheda resta come procedura riusabile.

Obiettivo: deploy + hardening light (SENZA mail client) + `mail-relay-lxc.sh` (Postfix smarthost)
sul container MTA, con verifica relay e niente open-relay.

> Sudo non-interattivo: usare l'helper `SUDO_ASKPASS` (vedi `README.md`). Il solo
> `echo "$PW" | sudo -S -v` non basta per i sudo non-tty interni agli script.

## Variabili (env)

```
HOST=root@192.168.14.20
NEW_USERNAME=simone
NEW_USER_PASSWORD=<fornita a inizio sessione>
DISABLE_SSH_PASSWORD=true
INSTALL_MAIL_CLIENT=false          # questo box È il relay: niente nullmailer
INTERNAL_NET=192.168.14.0/24
UPSTREAM_RELAY=                     # vuoto = consegna diretta via MX
ADMIN_EMAIL=alert@simoneradaelli.it
ASSUME_YES=true
```

## Passi

1. **Connettività**: `ssh $HOST 'hostname -f; systemd-detect-virt'`.
2. **Deploy repo**: `rsync -az --delete --exclude .git <repo>/ $HOST:/root/ubuntu-hardening/`
3. **Fase root (crea utente)** — come BASE ma stesso utente/chiavi:
   ```
   ssh $HOST "cd /root/ubuntu-hardening/scripts/lxc && \
     NEW_USERNAME=simone NEW_USER_PASSWORD='<pw>' DISABLE_SSH_PASSWORD=true ASSUME_YES=true \
     bash hardening-lxc-light.sh"
   ```
   Verifica utente + chiavi + login a chiave (`ssh simone@192.168.14.20 whoami`).
4. **Hardening light SENZA nullmailer**:
   ```
   ... INSTALL_MAIL_CLIENT=false ADMIN_EMAIL=alert@simoneradaelli.it ASSUME_YES=true \
   bash hardening-lxc-light.sh
   ```
   (deve loggare "salto nullmailer (questo box è il relay/MTA)")
5. **MTA (Postfix smarthost)**:
   ```
   ... INTERNAL_NET=192.168.14.0/24 UPSTREAM_RELAY= ADMIN_EMAIL=alert@simoneradaelli.it ASSUME_YES=true \
   bash mail-relay-lxc.sh
   ```

## Criteri di test (MTA)

- `sudo postconf -n | grep -E 'inet_interfaces|mynetworks|relayhost|smtpd_recipient_restrictions'`:
  - `inet_interfaces = all`
  - `mynetworks = 127.0.0.0/8 [::1]/128, 192.168.14.0/24`
  - `smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination`
- `systemctl is-active postfix` → active; `sudo ss -ltnp | grep ':25'` → in ascolto su tutte le if
- **UFW**: `sudo ufw status` → `25/tcp` ALLOW solo da `192.168.14.0/24` (+ SSH 22)
- **No open-relay**: da un host FUORI subnet (o simulando) un tentativo di relay verso dominio
  esterno deve essere rifiutato (`Relay access denied`). Verifica via `swaks`/telnet se disponibile,
  altrimenti documentare il check della restriction in `postconf -n`.

## Ricezione dal BASE (parte e2e)

Quando il BASE invia (vedi `agent-base.md`), su questo MTA:
- `/var/log/mail.log`: riga di ricezione `from=...relay/client=192.168.14.21` e poi consegna
- esito **`status=sent`** (accettato dall'MX remoto) vs `deferred`/`bounced`
- `mailq` / `postqueue -p` → vuota se consegnato
- Test deterministico interno: inviare a una mailbox **locale** sul MTA e leggere
  `/home/<user>/Maildir/` o `/var/mail/<user>` per provare la catena senza dipendere dal DNS esterno.

Al termine, scrivere `MTA_READY` in `status.md` e annotare l'esito (incluso se l'invio esterno
verso `alert@simoneradaelli.it` risulta `sent` o `deferred` → in tal caso valutare smarthost).
