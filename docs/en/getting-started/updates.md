---
title: Updates and rollback
audience: [self-hoster]
content_mode: explanation
track: user-docs
last_updated: 2026-11-13
---

# Updates and rollback

The appliance keeps itself up to date. You do not need to do anything, but it helps to know what happens, what you can set, and what to do when an update fails.

## What happens

1. **Every day** the appliance asks the registry `ghcr.io/nolte/kamerplanter-appliance` whether a new release is out. It only connects outwards; no port has to be open.
2. A new release is **downloaded in the background** and its signature is checked against the key built into the appliance. A release with a missing or wrong signature is discarded. Kamerplanter keeps running while this happens.
3. In the **maintenance window**, by default at night between 03:00 and 03:30 in the appliance's time, it restarts once into the new release. The web UI and the API are unavailable for a few minutes. Everything the new release needs was downloaded beforehand, including the Kamerplanter containers, so the restart needs no internet access.
4. Before the new release touches your data for the first time, the appliance **copies the database** to `/var/lib/kamerplanter/update/backup/`.
5. The new release has 20 minutes to become **healthy**: the configuration check passes, every container reports healthy, and the web UI and the API answer. Then the update counts as done.

The update replaces the system and the Kamerplanter version together. Your settings in `/etc/kamerplanter/kamerplanter.env`, the generated secrets, and your data stay as they are.

An appliance without internet access keeps running on its version and updates once it is online again.

## When an update fails

When the new release does not become healthy in time, the appliance **returns to the previous release on its own**, restarts once more, and **restores the database copy** from before the update. A failed release is never tried again; the appliance waits for the next one.

!!! warning "Data written after the update"
    The restore puts the data back to its state before the update. Anything written between the update and the return, at most the 20 minutes of the check after an automatic return, is lost.

What happened is recorded. Show it with:

```bash
kamerplanter-update status
```

```text
Update source:  ghcr.io/nolte/kamerplanter-appliance:stable
Running:        v0.2.0 (3f9a01c2d4e5)
Staged:         none
Previous:       v0.1.0 (8b1c7d0e2a6f)
Next window:    Sat 2026-11-14 03:00:00 UTC

Recent events:
  2026-11-13T03:04:11Z  apply  reboot  activating v0.2.0
  2026-11-13T03:05:40Z  update  backup  data backed up before the first start of v0.2.0
  2026-11-13T03:08:02Z  health  ok  v0.2.0 is healthy
```

`kamerplanter-update status --json` prints the same as JSON. The console shows the running version and the next window above the login prompt.

## Returning to the previous release yourself

If a release works but something is wrong with it, return to the previous one:

```bash
kamerplanter-update rollback
```

The appliance restarts into the previous release and restores the database copy from before the update; everything written since the update is lost. Only the release directly before the current one is available, and only while its database copy is kept, by default 7 days. The release you left is not installed again.

## Settings

Put these into `/etc/kamerplanter/kamerplanter.env`:

| Setting | Default | Meaning |
|---|---|---|
| `UPDATE_WINDOW` | `03:00` | Start of the maintenance window, `HH:MM` in the appliance's time; the restart happens within 30 minutes after it |
| `UPDATE_HEALTH_TIMEOUT` | `20` | Minutes a new release has to become healthy |
| `UPDATE_BACKUP_KEEP_DAYS` | `7` | Days a database copy from before an update is kept |

After changing `UPDATE_WINDOW`, run `systemctl daemon-reload`. The appliance's time zone is UTC unless you set another one with `timedatectl set-timezone`.

There is room needed for the database copy: an update is not activated while `/var` has less free space than the database plus a margin; the record says so.

## Choosing when

```bash
kamerplanter-update apply-now       # download and activate at once
kamerplanter-update postpone 7      # no activation for 7 days (1-30)
kamerplanter-update resume          # end a postponement
```

A postponement ends on its own; afterwards updates continue in the window.

## An appliance that does not update

An appliance installed from a proof-of-concept build before v0.1.0 has no registry as its update source and never updates. It lacks the `kamerplanter-update` command, and `bootc status` shows an image name starting with `localhost/`. Install the current release on it instead, after backing up `/etc/kamerplanter/` and the data.
