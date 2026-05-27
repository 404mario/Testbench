---
name: project-nvl72-ssh
description: "NVL72 18-node SSH trust model — single shared ed25519 keypair across all compute nodes, root-to-root, established 2026-05-27."
metadata: 
  node_type: memory
  type: project
  originSessionId: ee934ea8-ab64-43ac-ae31-d0f9392fd7ee
---

**State (2026-05-27):** All 18 NVL72 compute nodes (192.168.15.137–154) share a single ed25519 keypair (`pega-bench-20260527`, fingerprint `AAAAC3NzaC1lZDI1NTE5AAAAIO/ihn8wiCj/rxvP8SigOYTR2iuUTyFiy8StmnBkuUAN`) for root-to-root passwordless SSH in any direction. Each node has it as both `/root/.ssh/id_ed25519` and in its own `authorized_keys`. `~/.ssh/config` on every node sets `StrictHostKeyChecking=accept-new` for `192.168.15.*`. `/root/.ssh/known_hosts` was preloaded with ed25519+rsa+ecdsa host keys for all 18 IPs (no first-connect yes/no prompts).

**Why:** chosen "share one key" over "every node has its own + cross-authorize" because the cluster acts as one logical machine for distributed workloads (NCCL, mpirun, pdsh). Simpler ops, no N×N authorized_keys management. Trade-off accepted: compromise of any one node = compromise of all 18.

**How to apply:**
- Adding a 19th node: copy `/root/.ssh/id_ed25519{,.pub}` + `config` + `known_hosts` from any existing node, append the pubkey to its authorized_keys, then `ssh-keyscan` the new IP and append to known_hosts on all 18.
- Rotating the key: regenerate on pega, distribute to all 18, then `ssh-copy-id` the new pub and remove the old line from every `authorized_keys`. Coordinate — split-key state breaks multi-node jobs.
- Backups of pre-existing keys are at `/root/.ssh/id_ed25519{,.pub}.bak.20260527` on each of the 17 non-pega nodes (pega kept its original since it was generated same day). Old `~/.ssh/config` on pega backed up to `config.bak.20260527`.

**Hostname gotcha:** all 18 nodes report `hostname` = `pega` (shared image, per-node hostname never set). NCCL/MPI logs will be ambiguous — disambiguate by IP. Distinct identity confirmed via different `product_serial` (e.g. .137=264153500005, .140=265103730016, .145=264153500025) and IP.

**Bootstrap detail (one-time):** pega pubkey was pushed via `sshpass -e ssh-copy-id` from within a Claude Code session because `!`-mode bash has no TTY for `getpass()`. Root password was provided in conversation transcript on 2026-05-27 — if persistent transcript is a concern, rotate `abcdef` → strong per-node password (but then we lose the convenience of sshpass for future bulk ops). See [[project-gb300-bringup]] for the broader cluster context.
