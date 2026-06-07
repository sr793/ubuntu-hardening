# Status board — coordinamento agenti

Aggiornare questo file man mano. Stati: `PENDING` | `IN_PROGRESS` | `DONE` | `BLOCKED`.

## Handshake

- [ ] `LIGHT_READY`  — script light validato e pronto al deploy
- [x] `MTA_READY`    — MTA configurato e in ascolto, pronto a ricevere dal BASE (2026-06-07)
- [x] `E2E_DONE`     — test end-to-end mail completato (2026-06-07): BASE→MTA, alert@ status=sent (Outlook) + local maildir status=sent

## Agente BASE (192.168.14.21) — DONE (2026-06-07)

FQDN: `ubuntu-2204-lxc-lite.hsp.simoneradaelli.it` | virt: lxc | Ubuntu 22.04

| Step | Esito | Note |
|------|-------|------|
| Connettività | OK | hostname -f + systemd-detect-virt=lxc |
| Deploy repo | OK | rsync in /root e /home/simone (esclude .git) |
| Fase root (crea utente) | OK | utente simone, 2 chiavi in authorized_keys, /etc/sudoers.d/simone "parsed OK", PermitRootLogin no, AllowUsers simone (root login disabilitato come da policy) |
| Login a chiave simone | OK | `ssh -o BatchMode=yes simone@.21 whoami` → simone, anche dopo restart ssh dell'hardening |
| Hardening light | OK | exit 0; RELAY_HOST=192.168.14.20, INSTALL_MAIL_CLIENT=true. Eseguito come simone con sudo via askpass helper (poi rimosso). Nota op: keepalive `sudo -n -v` non bastava per i `sudo` non-tty dello script → usato shim `sudo -A`+SUDO_ASKPASS |
| UFW solo 22 | OK | `sudo ufw status verbose` → solo `22/tcp ALLOW IN` (v4+v6) + regole loopback; default deny incoming |
| ssh/fail2ban/nullmailer active | OK | `systemctl is-active` → tutti active. sshd -t OK. sshd -T: passwordauthentication no, permitrootlogin no, allowusers simone. fail2ban-client status sshd → jail attiva |
| unattended-upgrades dry-run | OK | `--dry-run --debug` nessun errore di config (NO_CONFIG_ERRORS) |
| nullmailer config | OK | /etc/nullmailer/remotes=`192.168.14.20 smtp --port=25`, adminaddr=`alert@simoneradaelli.it`, mail (bsd-mailx) presente |
| E2E invio mail | OK | external EB725A789→status=sent (relay Outlook 52.101.68.18, 250 2.6.0); local EC8C1A78A→status=sent (delivered to maildir). Coda nullmailer BASE vuota, mailq BASE+MTA vuote |

## Agente MTA (192.168.14.20) — DONE (2026-06-07)

FQDN: `ubuntu-2204-lxc-mta.hsp.simoneradaelli.it` | virt: lxc | Ubuntu 22.04

| Step | Esito | Note |
|------|-------|------|
| Connettività | OK | hostname -f + systemd-detect-virt=lxc |
| Deploy repo | OK | rsync in /root e /home/simone (esclude .git) |
| Fase root (crea utente) | OK | utente simone, 2 chiavi in authorized_keys, /etc/sudoers.d/simone "parsed OK", PermitRootLogin no |
| Login a chiave simone | OK | `ssh simone@.20 whoami` → simone (BatchMode) |
| Light INSTALL_MAIL_CLIENT=false | OK | log: "INSTALL_MAIL_CLIENT=false: salto nullmailer (questo box è il relay/MTA)". Upgrade completo, ssh/fail2ban active |
| mail-relay-lxc.sh | OK | postfix installato e active |
| postconf delta rete | OK | inet_interfaces=all; mynetworks=127.0.0.0/8 [::1]/128, 192.168.14.0/24; smtpd_recipient_restrictions=permit_mynetworks, reject_unauth_destination; relayhost vuoto; relay_domains vuoto; inet_protocols=ipv4 |
| UFW 25 solo subnet | OK | `25/tcp ALLOW IN 192.168.14.0/24` (commento "SMTP relay interno") + `22/tcp ALLOW IN`. Da Mac (192.168.11.135, fuori subnet) porta 25 BLOCCATA |
| No open-relay | OK (verificato) | reject_unauth_destination attivo + UFW blocca 25 da fuori subnet. Da localhost (in mynetworks) RCPT esterno è permesso (atteso). Test relay reale da host esterno NON eseguibile (UFW lo blocca a priori); demandato a verifica e2e dal BASE |
| Ricezione da BASE (status=sent) | OK (2026-06-07) | connect from 192.168.14.21; EB725A789 (→alert@) relay=Outlook status=sent; EC8C1A78A (→simone@mta) relay=local status=sent (delivered to maildir). mailq vuota |
| Test mail LOCALE | OK | `mail -s local-test-mta simone` → status=sent (delivered to maildir), recapito in /home/simone/Maildir/new/, From riscritto in noreply@FQDN, mailq vuota |

## Problemi / decisioni

-
