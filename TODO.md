# TODO — Hardening LXC Proxmox

Elenco delle attività aperte. Spuntare quando completate.

## Host Proxmox

- [ ] **Hardening host Proxmox** — script (`scripts/proxmox-host/hardening-host.sh`) o
  documento/checklist. Componenti tipici lato host:
  - auditd con ruleset base
  - sysctl / kernel hardening
  - SSH hardening dell'host
  - firewall (`pve-firewall` / UFW)
  - unattended-upgrades
  - eventuale AIDE

  Oggi nel progetto è solo un promemoria concettuale (vedi note in `CLAUDE.md`):
  auditd e kernel hardening vanno fatti sull'host, non nei container LXC. Manca però
  la procedura/automazione effettiva.

## Repository

- [ ] **Rinominare il repository** `sr793/ubuntu-hardening` con un nome più aderente
  (ora copre full + light + MTA centrale). Passi: 1) rename su GitHub (Settings → General);
  2) `git remote set-url origin https://github.com/sr793/<nuovo-nome>.git`;
  3) opzionale `mv` della cartella locale (farlo a sessione chiusa). `gh` non è installato.
