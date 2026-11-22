---
title: Configuration
audience: [self-hoster]
content_mode: reference
track: user-docs
last_updated: 2026-11-16
---

# Configuration

The Kamerplanter settings come from four layers. A value in a later layer wins over the same key in an earlier one.

| Layer | File | Who writes it |
|---|---|---|
| Defaults | `/usr/share/kamerplanter/kamerplanter.env` | The image; replaced by every update |
| [Provisioning](provisioning.md) | `/var/lib/kamerplanter/provisioning/provisioning.env`, then `/var/lib/kamerplanter/provisioning/settings.env` | cloud-init, from the provisioning data; empty without it |
| Secrets | `/etc/kamerplanter/secrets.env` | The appliance, once per key: generated or provisioned |
| Your own values | `/etc/kamerplanter/kamerplanter.env` | You; kept across updates and rollbacks |

With a [data disk](../getting-started/data-disk.md), `/etc/kamerplanter/` and `/var/lib/kamerplanter/pinned/` lie on that disk; the paths stay the same. The provisioning layer stays on the system disk.

Each line is `KEY=VALUE`, taken literally: quotes are not removed, leading whitespace and lines starting with `#` are skipped. On every boot the appliance merges and checks the layers and writes the result to `/run/kamerplanter/`; the services read only that result. Apply a change with:

```bash
systemctl restart kamerplanter.target
```

## Reaching the appliance by its address

The defaults expect the web UI at `http://localhost:8080`. When you open it under the appliance's address or a host name, set that origin in your file, for example:

```ini
CORS_ORIGINS=["http://kamerplanter.local:8080"]
FRONTEND_URL=http://kamerplanter.local:8080
```

## Generated secrets

On every boot the appliance generates each required secret that is still missing: `ARANGODB_PASSWORD`, `JWT_SECRET_KEY`, `FERNET_KEY`, `ERASURE_TOMBSTONE_SALT`, and `LOG_PSEUDONYM_SALT`. A secret that a later release newly requires is generated on that release's first boot. The exception are the three values under [Values that must not change](#values-that-must-not-change): once a service has started with one of them, it is not generated again but has to come back from a backup. A new `JWT_SECRET_KEY` only ends all sessions, a new `LOG_PSEUDONYM_SALT` only breaks the correlation with older log lines.

To use your own value instead, put it into `/etc/kamerplanter/kamerplanter.env`, ideally before the first start. To supply it before the first boot, use the provisioning data (`kamerplanter:` → `secrets:`) or the system credential `kamerplanter.secret.<KEY>`; see [Provisioning](provisioning.md#secrets).

## Updates

`UPDATE_WINDOW`, `UPDATE_HEALTH_TIMEOUT`, and `UPDATE_BACKUP_KEEP_DAYS` control when updates are activated and how they are checked; see [Updates and rollback](../getting-started/updates.md#settings). The configuration check rejects a window that is not `HH:MM` and a timeout or keeping period that is not a whole number, a timeout above 9999 minutes, or a keeping period of more than six digits.

## Data disk and backup disk

| Setting | Default | Meaning |
|---|---|---|
| `DATA_DISK` | empty | The data disk, as a `/dev/disk/by-id/` or `/dev/disk/by-uuid/` path; empty: none |
| `DATA_DISK_FORCE` | `0` | `1` formats a named data disk that carries another file system or partition table, once per device |
| `BACKUP_DISK` | empty | The backup disk, named the same way |
| `BACKUP_DISK_FORCE` | `0` | `1` formats a named backup disk that carries another file system or partition table, once per device |

These four settings count in your own file only while no data disk is set up. Once one is, that file lies on the data disk, so the appliance ignores them there and says so in `systemctl status kamerplanter-data-disk`. In the [provisioning layer](provisioning.md#lifecycle-of-the-settings) they're always ignored. Set them on the system disk instead, as root:

```bash
/usr/libexec/kamerplanter/disks name backup /dev/disk/by-id/ata-Example_SSD_ABC123
```

The command writes `/var/lib/kamerplanter/disks/naming.env`; add `force` after the path to format the disk once although it carries other signatures, or give `none` instead of a path to remove the naming.

A provisioner passes the same as the system credentials `kamerplanter.data-disk`, `kamerplanter.data-disk-force`, `kamerplanter.backup-disk`, and `kamerplanter.backup-disk-force`. The key of an encrypted disk is never a setting here, since this file lies on the data disk: it comes as the credential `kamerplanter.data-disk-key` or `kamerplanter.backup-disk-key`, or as the file of that name in `/var/lib/kamerplanter/disks/keys/`. The configuration check rejects a disk named by any other kind of path. See [Data disk and backup disk](../getting-started/data-disk.md).

## Checks before the services start

The services stay stopped, with a message in `systemctl status kamerplanter-config`, when:

- `FERNET_KEY` is not a valid Fernet key (44 characters, URL-safe base64)
- `ERASURE_TOMBSTONE_SALT`, `LOG_PSEUDONYM_SALT`, or a set `TENANT_EXPORT_SIGNING_SECRET` is shorter than 32 characters
- `JWT_SECRET_KEY` or the database password is empty or a known default
- a [provisioned](provisioning.md) `JWT_SECRET_KEY` is shorter than 32 characters or a provisioned database password shorter than 16 characters, before the services first started; set in your file, kept in `secrets.env`, or provisioned to an installation that has already started, such a short value only causes a warning that names the key, so an existing installation keeps starting; replace it with a longer one (for the database password, change it in the database first, then remove its pin as the warning says)
- `ARANGODB_USERNAME` is set to anything other than `root`: the database image creates only its root user, and `ARANGO_ROOT_PASSWORD` is always taken from `ARANGODB_PASSWORD`
- a line in one of the files is not `KEY=VALUE`
- one of the values below changed or went missing after a service started with it

## Values that must not change

| Value | Why |
|---|---|
| `ERASURE_TOMBSTONE_SALT` | Keys the records of deleted accounts; must never change |
| `FERNET_KEY` | Stored credentials are encrypted with it and become unreadable |
| `ARANGODB_PASSWORD` | The database keeps the password it was created with |

Right before a service starts with one of them for the first time, a keyed digest (HMAC-SHA256) of it is recorded under `/var/lib/kamerplanter/pinned/`: the database password before ArangoDB starts, the other two before the API starts. The key is generated once per device and lies beside the records, in `/var/lib/kamerplanter/pinned/.key`; never delete it, and include it when you copy the directory (a `pinned/*` glob skips it), since without it no record can be checked and the services stay stopped. A value missing from `secrets.env` after that is not generated again; restore it from your backup. To change one deliberately, first do what its reason requires, for the database password: change it in the database, then set `ARANGODB_PASSWORD` in your file, then delete `/var/lib/kamerplanter/pinned/ARANGODB_PASSWORD.hmac` and restart. Earlier releases recorded an unkeyed digest in `/var/lib/kamerplanter/pinned/ARANGODB_PASSWORD` and so on; on an updated appliance such a record is checked as before and the keyed one is written beside it, without stopping the services. The unkeyed record is deleted at the first start after the update has passed its health check, so that the release an automatic rollback returns to still finds it. The message of a changed value names the files to delete. Where an unkeyed record is present, it decides: a value changed on a release before after a rollback (as its documentation describes) is accepted on the way back, and the keyed record is written anew. Once the unkeyed records are deleted, a manual return to a release before (`kamerplanter-update rollback`) no longer stops a missing value from being generated anew, since that release checks only the unkeyed records: before such a return, make sure `secrets.env` holds every value. The key protects copies of the records without it; whoever can read the whole directory, for example on an unplugged unencrypted data disk, has the key too and can still try short values against the records.

!!! warning "Backups"
    Back up `/etc/kamerplanter/secrets.env` together with your data. Data restored without the matching `FERNET_KEY` and `ERASURE_TOMBSTONE_SALT` loses its encrypted fields and deletion records. With a data disk, both lie on that disk; the disk itself is no backup, and the pre-update backup on a backup disk holds the databases only, not the secrets. The key of an encrypted disk is kept on the system disk; keep a copy of it as well.
