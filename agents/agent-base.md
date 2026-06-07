# Agente BASE — 192.168.14.21

> ✅ ESEGUITO (2026-06-07): tutti i criteri superati, e2e mail OK (esterno + locale, `status=sent`).
> Esiti in `status.md`. Questa scheda resta come procedura riusabile.

Obiettivo: deploy + test di `hardening-lxc-light.sh` sul container BASE, fino all'e2e mail.

## Variabili (env)

```
HOST=root@192.168.14.21
NEW_USERNAME=simone
NEW_USER_PASSWORD=<fornita a inizio sessione>
DISABLE_SSH_PASSWORD=true
RELAY_HOST=192.168.14.20
ADMIN_EMAIL=alert@simoneradaelli.it
INSTALL_MAIL_CLIENT=true
ASSUME_YES=true
```

## Passi

1. **Connettività**: `ssh $HOST 'hostname -f; systemd-detect-virt'` (atteso lxc).
2. **Deploy repo**:
   `rsync -az --delete --exclude .git <repo>/ $HOST:/root/ubuntu-hardening/`
3. **Fase root (crea utente)**:
   ```
   ssh $HOST "cd /root/ubuntu-hardening/scripts/lxc && \
     NEW_USERNAME=simone NEW_USER_PASSWORD='<pw>' DISABLE_SSH_PASSWORD=true ASSUME_YES=true \
     bash hardening-lxc-light.sh"
   ```
   Verificare: utente `simone` creato, `/home/simone/.ssh/authorized_keys` = `config/authorized_keys`
   (stesse 2 chiavi), `/etc/sudoers.d/simone` valido, PermitRootLogin no.
   ⚠️ Tenere aperta la sessione root corrente finché il login a chiave di `simone` non è verificato.
4. **Verifica login a chiave**: `ssh simone@192.168.14.21 'whoami'` → `simone` (senza password).
5. **Fase utente (hardening)**: lo script usa `sudo` con password → primare le credenziali.
   ```
   ssh simone@192.168.14.21 "cd /root/ubuntu-hardening/scripts/lxc 2>/dev/null || cd ~/ubuntu-hardening/scripts/lxc; \
     echo '<pw>' | sudo -S -v; \
     RELAY_HOST=192.168.14.20 ADMIN_EMAIL=alert@simoneradaelli.it INSTALL_MAIL_CLIENT=true ASSUME_YES=true \
     SUDO_ASKPASS=<askpass> bash hardening-lxc-light.sh"
   ```
   Nota: il repo è in /root (deploy come root); per la fase utente copiare/clonare il repo in
   una dir leggibile da `simone` (es. `/home/simone/ubuntu-hardening`) oppure rsync direttamente lì.

## Criteri di test (BASE)

- `sudo ufw status verbose` → solo `22/tcp` ALLOW (niente altro in ingresso)
- `sudo sshd -t` → nessun errore
- login a chiave di `simone` OK; `PasswordAuthentication no` attivo
- `systemctl is-active ssh fail2ban nullmailer` → tutti `active`
- `sudo fail2ban-client status sshd` → jail attiva
- `journalctl -u fail2ban -n50` → nessun crash (errori "mail command not found" tollerati se
  bsd-mailx non ancora pronto, ma non devono impedire l'avvio)
- `sudo unattended-upgrades --dry-run --debug` → nessun errore di configurazione
- nullmailer: `cat /etc/nullmailer/remotes` = `192.168.14.20 smtp --port=25`,
  `cat /etc/nullmailer/adminaddr` = `alert@simoneradaelli.it`

## E2E mail (dopo MTA_READY su status.md)

```
ssh simone@192.168.14.21 "echo 'corpo test e2e' | mail -s 'TEST e2e da BASE' alert@simoneradaelli.it"
```
- Subito dopo: coda nullmailer vuota → `mailq` vuota / `ls /var/spool/nullmailer/queue` vuoto
- `journalctl -t nullmailer -n20` → invio al relay riuscito
- Verifica lato MTA (vedi `agent-mta.md`): `status=sent` in `/var/log/mail.log`

Annotare l'esito in `status.md` (sezione BASE) con eventuali Message-ID per correlazione.
