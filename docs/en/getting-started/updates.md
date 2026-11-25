---
title: Updates and rollback
audience: [self-hoster]
content_mode: explanation
track: user-docs
last_updated: 2026-11-15
---

# Updates and rollback

The appliance keeps itself up to date. You do not need to do anything, but it helps to know what happens, what you can set, and what to do when an update fails.

## What happens

1. **Every day** the appliance asks the registry `ghcr.io/nolte/kamerplanter-appliance` whether a new release is out. It only connects outwards; no port has to be open.
2. A new release is **downloaded in the background** and its signature is checked against the key built into the appliance. A release with a missing or wrong signature is discarded, and so is a release older than the one running. Kamerplanter keeps running while this happens.
3. In the **maintenance window**, by default at night between 03:00 and 03:30 in the appliance's time, it restarts once into the new release. The web UI and the API are unavailable for a few minutes. Everything the new release needs was downloaded beforehand, including the Kamerplanter containers, so the restart needs no internet access.
4. Before the new release touches your data for the first time, the appliance **copies the database**: to `/var/lib/kamerplanter/update/backup/` on the system disk, or to a [backup disk or data disk](#where-the-backup-goes) when you have one.
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

`kamerplanter-update status --json` prints the same as JSON. The console shows the running version, a staged update, and the next window above the login prompt.

## Returning to the previous release yourself

If a release works but something is wrong with it, return to the previous one:

```bash
kamerplanter-update rollback
```

The appliance restarts into the previous release and restores the database copy from before the update; everything written since the update is lost. Only the release directly before the current one is available, and only while its database copy is kept, by default 7 days. The release you left is not installed again.

With a [data disk](data-disk.md) set up, the command refuses to return to a release that doesn't know data disks: that release would ignore the disk and run on what the system disk holds underneath, an old copy of your data or none, and generate new secrets. Stay on the current release then. When an update fails and the appliance returns on its own, it never refuses; if the release it returns to doesn't know data disks, the data disk was set up during that failed update, and the appliance first returns to the copy of your data on the system disk, which is unchanged. The disk is then no longer used until you name it again, as after a [failed move](data-disk.md#moving-an-appliance-onto-a-data-disk).

## Settings

Put these into `/etc/kamerplanter/kamerplanter.env`:

| Setting | Default | Meaning |
|---|---|---|
| `UPDATE_WINDOW` | `03:00` | Start of the maintenance window, `HH:MM` in the appliance's time; the restart happens within 30 minutes after it |
| `UPDATE_HEALTH_TIMEOUT` | `20` | Minutes a new release has to become healthy; 1 to 9999 |
| `UPDATE_BACKUP_KEEP_DAYS` | `7` | Days a database copy from before an update is kept; at least 3, a smaller number counts as 3; at most six digits |

After changing `UPDATE_WINDOW`, run `systemctl daemon-reload`. The appliance's time zone is UTC unless you set another one with `timedatectl set-timezone`.

There is room needed for the database copy: an update is not activated while no backup location has free space for the database plus 10 % and 512 MiB; the record says so. If the copy still cannot be made when the new release starts for the first time, the appliance returns to the previous release before the new one touches the data, and activates the update again in a later window.

## Where the backup goes

With a [backup disk or data disk](data-disk.md), the appliance takes the first of these locations that is usable and has room:

1. the backup disk `kp-backup`, in `update-backup/` at the top of the disk
2. the data disk `kp-data`, in `update-backup/` at the top of the disk
3. the system disk, in `/var/lib/kamerplanter/update/backup/`

A disk is skipped when it isn't set up, is missing, is mounted under another identity than the one it was set up with, or lacks the room. With an encrypted data disk, an unencrypted backup disk is skipped too. The update record names the location used and why the others were skipped:

```text
  2026-11-15T03:05:40Z  update  backup  data backed up before the first start of v0.3.0 on the data disk kp-data; not on the backup disk kp-backup: the backup disk kp-backup is missing or not mounted
```

The first update from a release that knows only the system disk puts its backup there, so that a rollback to that release finds it.

The record keeps where each backup is and a checksum, which covers the files, their permissions and owners, their extended attributes such as SELinux labels and ACLs, and their hard links. The checksum is checked before a restore, and again on the restored data before the services start. When the backup's disk is missing at a rollback, or the checksum doesn't match, the backup isn't restored and the services stay stopped; the console and `systemctl status kamerplanter-update-guard.service` say why. For a missing disk, attach it again, then reboot, or run `systemctl restart kamerplanter-backup-disk.service kamerplanter.target`. A damaged backup has to be replaced by hand from another backup. `kamerplanter-update status` lists every backup with its location. If the backup passes its check but the restored data does not, the volumes are already replaced, the services stay stopped, and the next boot copies the backup again.

## Choosing when

```bash
kamerplanter-update apply-now       # download and activate at once
kamerplanter-update postpone 7      # no activation for 7 days (1-30)
kamerplanter-update resume          # end a postponement
```

A postponement ends on its own; afterwards updates continue in the window.

## An appliance that does not update

An appliance installed from a proof-of-concept build before v0.1.0 has no registry as its update source and never updates. It lacks the `kamerplanter-update` command, and `bootc status` shows an image name starting with `localhost/`. Install the current release on it instead, after backing up `/etc/kamerplanter/` and the data.
