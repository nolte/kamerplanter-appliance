---
title: Configuration
audience: [self-hoster]
content_mode: reference
track: user-docs
last_updated: 2026-11-13
---

# Configuration

The Kamerplanter settings come from three files. A value in a later file wins over the same key in an earlier one.

| File | Content | Who writes it |
|---|---|---|
| `/usr/share/kamerplanter/kamerplanter.env` | Defaults | The image; replaced by every update |
| `/etc/kamerplanter/secrets.env` | Generated secrets | The appliance, once per key |
| `/etc/kamerplanter/kamerplanter.env` | Your own values | You; kept across updates and rollbacks |

Each line is `KEY=VALUE`, taken literally: quotes are not removed, leading whitespace and lines starting with `#` are skipped. On every boot the appliance merges and checks the three files and writes the result to `/run/kamerplanter/`; the services read only that result. Apply a change with:

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

To use your own value instead, put it into `/etc/kamerplanter/kamerplanter.env`, ideally before the first start.

## Checks before the services start

The services stay stopped, with a message in `systemctl status kamerplanter-config`, when:

- `FERNET_KEY` is not a valid Fernet key (44 characters, URL-safe base64)
- `ERASURE_TOMBSTONE_SALT`, `LOG_PSEUDONYM_SALT`, or a set `TENANT_EXPORT_SIGNING_SECRET` is shorter than 32 characters
- `JWT_SECRET_KEY` or the database password is empty or a known default
- `ARANGODB_USERNAME` is set to anything other than `root`: the database image creates only its root user, and `ARANGO_ROOT_PASSWORD` is always taken from `ARANGODB_PASSWORD`
- a line in one of the files is not `KEY=VALUE`
- one of the values below changed or went missing after a service started with it

## Values that must not change

| Value | Why |
|---|---|
| `ERASURE_TOMBSTONE_SALT` | Keys the records of deleted accounts; must never change |
| `FERNET_KEY` | Stored credentials are encrypted with it and become unreadable |
| `ARANGODB_PASSWORD` | The database keeps the password it was created with |

Right before a service starts with one of them for the first time, a digest is recorded under `/var/lib/kamerplanter/pinned/`: the database password before ArangoDB starts, the other two before the API starts. A value missing from `secrets.env` after that is not generated again; restore it from your backup. To change one deliberately, first do what its reason requires, for the database password: change it in the database, then set `ARANGODB_PASSWORD` in your file, then delete `/var/lib/kamerplanter/pinned/ARANGODB_PASSWORD` and restart.

!!! warning "Backups"
    Back up `/etc/kamerplanter/secrets.env` together with your data. Data restored without the matching `FERNET_KEY` and `ERASURE_TOMBSTONE_SALT` loses its encrypted fields and deletion records.
