---
title: Configuration
audience: [self-hoster]
content_mode: reference
track: user-docs
last_updated: 2026-11-13
---

# Configuration

The Kamerplanter services read their settings from three files. A value in a later file wins over the same key in an earlier one.

| File | Content | Who writes it |
|---|---|---|
| `/usr/share/kamerplanter/kamerplanter.env` | Defaults | The image; replaced by every update |
| `/etc/kamerplanter/secrets.env` | Generated secrets | The appliance, once per key |
| `/etc/kamerplanter/kamerplanter.env` | Your own values | You; kept across updates and rollbacks |

Each line is `KEY=VALUE`, taken literally: quotes are not removed. Apply a change with:

```bash
systemctl restart kamerplanter.target
```

## Generated secrets

On every boot the appliance generates each required secret that is still missing: `ARANGO_ROOT_PASSWORD` and `ARANGODB_PASSWORD` (one value), `JWT_SECRET_KEY`, `FERNET_KEY`, `ERASURE_TOMBSTONE_SALT`, and `LOG_PSEUDONYM_SALT`. A secret that a later release newly requires is generated on that release's first boot.

To use your own value instead, put it into `/etc/kamerplanter/kamerplanter.env`, ideally before the first start.

## Checks before the services start

The services stay stopped, with a message in `systemctl status kamerplanter-config`, when:

- `FERNET_KEY` is not a valid Fernet key (44 characters, URL-safe base64)
- `ERASURE_TOMBSTONE_SALT`, `LOG_PSEUDONYM_SALT`, or a set `TENANT_EXPORT_SIGNING_SECRET` is shorter than 32 characters
- `JWT_SECRET_KEY` or the database password is empty or a known default
- `ARANGO_ROOT_PASSWORD` and `ARANGODB_PASSWORD` differ while the database user is `root`
- one of the values below changed after the first start

## Values that must not change

| Value | Why |
|---|---|
| `ERASURE_TOMBSTONE_SALT` | Keys the records of deleted accounts; must never change |
| `FERNET_KEY` | Stored credentials are encrypted with it and become unreadable |
| `ARANGODB_PASSWORD` | The database keeps the password it was created with |

The first start records a digest of each under `/var/lib/kamerplanter/pinned/`. To change one deliberately, first do what its reason requires, for the database password: change it in the database, then set both password keys in your file, then delete `/var/lib/kamerplanter/pinned/ARANGODB_PASSWORD` and restart.

!!! warning "Backups"
    Back up `/etc/kamerplanter/secrets.env` together with your data. Data restored without the matching `FERNET_KEY` and `ERASURE_TOMBSTONE_SALT` loses its encrypted fields and deletion records.
