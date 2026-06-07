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
