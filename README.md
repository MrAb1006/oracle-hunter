# oci-hunter

A GitHub Actions bot that **hunts for Oracle Cloud Always-Free `A1.Flex` capacity every 5 minutes** and, the moment a slot opens, grabs it and sends a Telegram alert.

## Why

The free-tier A1 (2 OCPU / 12 GB ARM) has been capacity-blocked in Hyderabad since June 2026 (shape limit officially halved and capacity is scarce). Launch attempts must be repeated until one succeeds. A 5-minute cron on a **public** repo costs nothing (unlimited minutes) and fires ~288 attempts/day.

## Safety rails (hard-coded)

- Launch shape is only ever `VM.Standard.A1.Flex` with `ocpus: 2, memoryInGBs: 12` - the exact free-tier share. No PAYG shapes, no bigger configs, ever.
- If the instance `riya-a1` already exists -> the run exits green.
- "Out of host capacity" from Oracle -> green exit, retried in 5 min.
- All credentials ride in encrypted GitHub secrets; the signing key is materialized only inside the runner (`chmod 600`, nothing logged).
- Read-only Oracle resources are listed every run; the VCN/subnet/gateway are reused, not duplicated.

## Secrets required

| Secret | Meaning |
|---|---|
| `OCI_CLI_USER` | user OCID |
| `OCI_CLI_TENANCY` | tenancy OCID |
| `OCI_CLI_FINGERPRINT` | API-key fingerprint (`18:93:31:...`) |
| `OCI_CLI_REGION` | `ap-hyderabad-1` |
| `OCI_CLI_KEY_CONTENT` | contents of the Oracle API private key PEM |
| `TELEGRAM_BOT_TOKEN` | bot token for the success notification |
| `TELEGRAM_CHAT_ID` | chat id for the notification |
| `VM_SSH_PUBKEY` | SSH public key injected into the VM |

## When it succeeds

The instance appears in the Oracle console as `riya-a1`, a Telegram message carries the public IP, and you deploy the app with:

```
.\deploy\push.ps1 -VmHost <IP>
```

Riya then runs on the A1 (2 OCPU / 12 GB) instead of the x86 Micro.

## Keep-alive (important!)

GitHub **auto-pauses scheduled workflows after 60 days of repository inactivity**, and its scheduler throttle drops the crowded `*/5 * * * *` slots entirely (verified live: zero schedule runs in over an hour). So reliability comes from two layers:

### Layer 1 - off-peak cron
The workflow fires at `13,33,53 * * * *` (every 20 min at near-empty scheduler slots). Each firing still makes 6 real launch attempts (~432/day).

### Layer 2 - the Oracle VM pings GitHub itself (guaranteed, no 3rd party)
The Riya VM (`riya-voice`, always on) runs a root cron job that force-dispatches
this workflow every 15 minutes:

- `/etc/cron.d/riya-hunter` - the cron entry (runs every 15 min, ~37 s offset)
- `/etc/riya-hunter.token` - the fine-grained PAT, root-owned `600`, scoped
  ONLY to `oracle-hunter` with permission `Actions: Read and write`

Verified live: the dispatched run appears on GitHub seconds later (HTTP 204 ->
in_progress run). cron-job.org is no longer needed; if you ever want it as a
back-up anyway, its API works only with account email+password (no API keys).


To rotate the token: GitHub -> Settings -> Developer settings -> Fine-grained tokens -> regenerate, rewrite `sudo tee /etc/riya-hunter.token < new_token`; it is picked up on the next 15-min tick.

## Files

- `.github/workflows/hunt.yml` - cron + dispatch trigger, concurrency lock
- `hunt.sh` - the hunter itself

