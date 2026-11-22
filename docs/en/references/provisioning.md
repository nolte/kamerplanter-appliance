---
title: Provisioning
audience: [self-hoster]
content_mode: reference
track: user-docs
last_updated: 2026-11-16
---

# Provisioning

Provisioning data sets up an appliance at boot without logging in: host name, network, an SSH key for root, and your own Kamerplanter settings and secrets. The appliance reads it with cloud-init. An automation such as a Terraform module uses the same interface.

Without provisioning data cloud-init stays disabled, and the appliance behaves as before: it gets its address through DHCP and completes its first-boot setup.

## Sources

| Source | How |
|---|---|
| NoCloud drive | A drive labelled `CIDATA`, formatted vfat or ISO 9660: a virtual drive of the VM, or a USB stick on your own hardware |
| Seed URL | `ds=nocloud;s=<URL>` on the kernel command line or as the SMBIOS system serial number; the URL serves `meta-data` and `user-data` |
| Seed files | The same files under `/var/lib/cloud/seed/nocloud/` on the system disk, together with a file of your own in `/etc/cloud/cloud.cfg.d/`; see below |
| Hetzner Cloud | The metadata service of the provider; enter the user-data when you create the server |
| OVHcloud | The OpenStack metadata service, or the ConfigDrive that OpenStack and OVHcloud's "Bring Your Own Image" attach |

!!! note
    The appliance reads the Hetzner Cloud and OVHcloud sources, but they haven't been tested on a real server yet.

A NoCloud drive and the seed files hold these files:

| File | Content |
|---|---|
| `meta-data` | `instance-id:` and `local-hostname:` |
| `user-data` | The cloud-config, starting with the line `#cloud-config` |
| `network-config` | Optional, a static network configuration |

A vfat drive, as an image file for a VM or written to a USB stick:

```bash
truncate -s 4M cidata.img
mkfs.vfat -n CIDATA cidata.img
mcopy -i cidata.img meta-data user-data network-config ::/
```

A seed URL as the system serial number of a QEMU VM, the URL ending in `/`:

```bash
-smbios 'type=1,serial=ds=nocloud;s=http://10.0.2.2:8099/'
```

Whoever answers at a seed URL decides what the appliance runs as root, on every boot. Serve it over `https://` from a host you control, or over plain HTTP only inside a network you trust, and remove the URL once the appliance has started.

### Seed files

Seed files need a configuration file of your own in `/etc/cloud/cloud.cfg.d/`, for example `90-nocloud-seed.cfg`, with this single line:

```yaml
datasource_list: [ NoCloud, None ]
```

cloud-init chooses its source before `/var` is mounted. While it chooses among several sources, it doesn't find the seed files; with NoCloud as the only one, it reads them later. The image doesn't ship this file, because cloud-init would then run on every boot and no longer read the metadata services. Give the file a name that sorts after the image's `50-kamerplanter.cfg`, and keep the key on one line.

## What cloud-init applies

- the host name
- the network configuration, such as a static IPv4 address, gateway, and DNS servers
- the SSH keys of `ssh_authorized_keys`, for root

No default user is created, not even with `users: [ default ]`. SSH never accepts a password, also when the user-data sets `ssh_pwauth: true`. cloud-init doesn't grow partitions or file systems.

The appliance generates its SSH host keys on its first boot and keeps them, also on a boot that cloud-init treats as a new instance: a boot on which a seed URL or the metadata service doesn't answer, or a changed `instance-id`. The next boot on which the source answers again returns to the first instance, and cloud-init doesn't set it up again. SSH clients therefore don't report a changed host key. A copy of an installed system disk, such as a snapshot that a second server is created from, keeps the host keys of the original like everything else on the disk; set up a second appliance from the image instead.

### Static network

Two forms of network-config version 2 are supported: each `ethernets` entry keyed by the name of the interface on the appliance, or matched by `match: macaddress:` together with `set-name:`. A `match:` without `set-name:` isn't supported; the connection never comes up, and the appliance stays on DHCP.

```yaml
version: 2
ethernets:
  lan0:
    match:
      macaddress: "52:54:00:12:34:56"
    set-name: lan0
    dhcp4: false
    addresses: [192.168.1.50/24]
    routes:
      - to: default
        via: 192.168.1.1
    nameservers:
      addresses: [192.168.1.1]
```

Whether the network configuration that Proxmox VE generates for its cloud-init drive works hasn't been tested yet. To be sure, supply your own network-config in one of the two forms above.

## Kamerplanter settings and secrets

Put your settings under `kamerplanter:` → `settings:` and your secrets under `kamerplanter:` → `secrets:`:

```yaml
#cloud-config
hostname: kamerplanter
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample you@example
kamerplanter:
  settings:
    FRONTEND_URL: "http://kamerplanter.local:8080"
    CORS_ORIGINS: '["http://kamerplanter.local:8080"]'
    UPDATE_WINDOW: "04:15"
  secrets:
    JWT_SECRET_KEY: "4f0c7d9e2b1a8c6e5d3f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d"
write_files:
  - path: /var/lib/kamerplanter/provisioning/provisioning.env
    permissions: '0600'
    content: |
      REGISTRATION_MODE=invite_only
```

Each entry under `settings:` becomes one `KEY=VALUE` line. A number or `true`/`false` is written as its text, an empty value as `KEY=`. Quote every value: `UPDATE_WINDOW: 22:30` without quotes is the number 1350 in YAML, and a value in brackets is a list. A list, a map, or a value over several lines keeps the services stopped. Every value under `secrets:` has to be quoted text.

Instead of the map, or in addition to it, `write_files` can write `/var/lib/kamerplanter/provisioning/provisioning.env` in the format of [your own file](configuration.md). For a key that both set, the map wins. Neither ever writes `/etc/kamerplanter/kamerplanter.env`.

`write_files` runs once per instance, on the first boot with a new `instance-id`. An entry with `defer: true` applies only from the next boot. A boot on which the source doesn't answer, such as a seed URL that is down, doesn't write your files again, and neither does the boot on which it answers again: cloud-init remembers which instances it has set up, so your edits to `provisioning.env` stay, and so does the hostname from the provisioning data.

## Lifecycle of the settings

The settings form the provisioning layer, between the image's defaults and `secrets.env`; your own file wins over them. See [Configuration](configuration.md).

| File | Written |
|---|---|
| `/var/lib/kamerplanter/provisioning/provisioning.env` | By `write_files`, once per instance; you may edit it in place |
| `/var/lib/kamerplanter/provisioning/settings.env` | From `kamerplanter:` → `settings:`, on every boot with provisioning data; your edits are lost |

Both lie on the system disk, also with a [data disk](../getting-started/data-disk.md), readable by root only. On every boot with provisioning data, `settings.env` is renewed from the map, an empty map included, so a changed value applies after the next boot. On a boot without provisioning data it stays as it is: the settings stay in effect after you detach the source. They apply from the first start of the services; a provisioned `UPDATE_WINDOW` sets the maintenance window from the first boot.

A provisioned value is checked like a value of your file. An invalid one keeps the services stopped, and the message names the provisioning layer:

```bash
systemctl status kamerplanter-config
```

```text
Kamerplanter configuration is invalid; the services stay stopped:
  - UPDATE_WINDOW is not a time of day as HH:MM (the window starts at 03:00 until it is fixed) (set in the provisioning layer (kamerplanter: -> settings: of the provisioning data, in /var/lib/kamerplanter/provisioning/settings.env))
```

Fix it in the provisioning data and reboot, or set it in `/etc/kamerplanter/kamerplanter.env`, which wins, and run `systemctl restart kamerplanter.target`.

Two kinds of keys are treated differently in the provisioning layer:

- `DATA_DISK`, `BACKUP_DISK`, `DATA_DISK_FORCE`, and `BACKUP_DISK_FORCE` are ignored, with a message. Name a disk with `disks name` or as a system credential; see [Data disk and backup disk](../getting-started/data-disk.md#setting-up-a-disk).
- A generated secret, such as `FERNET_KEY`, under `settings:` is passed through with a warning that names the key. It stays in the provisioning layer in plain text; put it under `secrets:` instead.

## Secrets

The appliance takes `kamerplanter:` → `secrets:` into `/etc/kamerplanter/secrets.env` once per instance, on the first boot on which it can write that file. It fills only keys the file doesn't hold yet. When the file holds a different value, also on an adopted data disk, that value is kept; a warning names the key, never the value, and the services start as usual. A secret never appears in the provisioning layer, the journal, the console, or the output of a command. Once taken over, it's kept like a [generated secret](configuration.md#generated-secrets); back it up the same way.

The appliance takes over these keys only:

| Key | Rule beyond 1 to 4096 printable ASCII characters on one line |
|---|---|
| `ARANGODB_PASSWORD` | At least 16 characters, not a known default |
| `JWT_SECRET_KEY` | At least 32 characters, not the upstream placeholder |
| `FERNET_KEY` | A Fernet key: 44 characters, URL-safe base64 |
| `ERASURE_TOMBSTONE_SALT` | At least 32 characters |
| `LOG_PSEUDONYM_SALT` | At least 32 characters |
| `TENANT_EXPORT_SIGNING_SECRET` | At least 32 characters |

Any other key, or a value that breaks a rule, keeps the services stopped, and nothing provisioned is written. Fix the provisioning data and reboot.

`ERASURE_TOMBSTONE_SALT`, `FERNET_KEY`, and `ARANGODB_PASSWORD` [must not change](configuration.md#values-that-must-not-change) once a service has started with them. A provisioned value of one of them restores a missing key only when it matches the value Kamerplanter started with; otherwise the services stay stopped until you restore the key from your backup.

The appliance has no command that rotates secrets. To change one later, set it in `/etc/kamerplanter/kamerplanter.env`; changing the map of the same instance has no effect.

## Secrets as system credentials

On Proxmox VE and any other QEMU guest, a secret can also come as the system credential `kamerplanter.secret.<KEY>`, one per key, for example as an SMBIOS type 11 string:

```bash
-smbios type=11,value=io.systemd.credential:kamerplanter.secret.JWT_SECRET_KEY=4f0c7d9e2b1a8c6e5d3f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d
```

On Proxmox VE, add the same as `args:` to the VM configuration:

```text
args: -smbios type=11,value=io.systemd.credential:kamerplanter.secret.JWT_SECRET_KEY=4f0c7d9e2b1a8c6e5d3f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d
```

Only `root@pam` may set `args`.

Don't pass a secret with `systemd.set_credential=` on the kernel command line: every local user and every container can read `/proc/cmdline`.

A credential is read on every boot and fills a key that `secrets.env` doesn't hold, under the same keys and rules as the map. When a credential and the map supply the same missing key, the credential wins.

!!! warning "Credentials stay readable"
    An SMBIOS credential stays readable for root as long as the appliance runs, in `/sys/firmware/dmi/tables/` and in `/run/credentials/@system/`. It also lies in plain text in the VM configuration. Remove it from the VM once the secret is taken over.

## Protection

**cloud-init's copies are deleted.** cloud-init stores the user-data, and every secret in it, again on each boot while the source is attached. On every boot, after the settings are renewed and the secrets taken over, the appliance deletes `user-data.txt`, `user-data.txt.i`, `cloud-config.txt`, and `obj.pkl` in each directory under `/var/lib/cloud/instances/`, and `combined-cloud-config.json` and `instance-data-sensitive.json` in `/run/cloud-init/`. Before that, it replaces each provisioned secret with `REDACTED` in what's there and in cloud-init's logs `/var/log/cloud-init*.log`, rotated ones included; a compressed log that holds a secret is deleted. The copies go last, so a boot that ends early leaves them, and the next boot finds the secrets in them even when the source is gone. They're also kept, unchanged, when the appliance can't finish: when jq is missing or can't take the secrets out of a copy or out of the combined cloud-config, when a file with a secret can't be rewritten, when `/var/lib/cloud`, `/var/lib/cloud/instances`, an instance directory in it, `/run/cloud-init`, or one of the copies is a symbolic link, or, when there's something to scrub, when `/var/lib/cloud/data` or the status or result in it, `/var/log`, or one of cloud-init's logs is one; the appliance doesn't follow a link, and names each one. A copy that can't be deleted is named, and the others are deleted. In each case the unit fails and names the cause, the services keep running, and the next boot tries again. Until the cause is fixed, the copies and the logs keep the secrets in plain text, readable only by root. The copies are kept whole on purpose: a redacted copy would no longer let a later boot learn the secrets and scrub the logs. The secrets are learned from every copy that can be read; when no copy of an instance can be read, cloud-init's logs are deleted instead and the error messages in cloud-init's status are replaced with `REDACTED`; a log that can't be deleted then is named, the copies are kept, and the unit fails. A value shorter than 8 characters isn't searched for; the message names its key. cloud-init's record of the instance is kept, so once-per-instance steps don't run again. The result is in:

```bash
systemctl status kamerplanter-cloud-init-scrub
```

Seed files under `/var/lib/cloud/seed/` are your source, not a copy, and are left alone. When they hold a secret, the appliance warns. The directory is readable for root only.

The appliance can only replace secrets it found in the user-data that cloud-init read. When the user-data isn't valid YAML, for example because a secret starting with `*`, `&`, or `@` isn't quoted, cloud-init reads none of it and can quote the faulty line in its log and in the journal, where it stays. Quote every secret.

**Only root reaches the metadata service.** The address `169.254.169.254` hands out the provisioning data, secrets included, to whoever asks. Only root reaches it, from before the first container starts. Other local users and the containers don't, and the containers reach no other link-local address (`169.254.0.0/16`) either. Replies to a client that itself has a link-local address still reach it. The appliance masks `nftables.service`, whose reload and stop would remove these rules, and loads them again every minute, so that they are back within a minute when something else removes or changes them. A host firewall run through `nftables.service` is therefore not available; after the update that introduces the mask, a device on which it was enabled no longer loads `/etc/sysconfig/nftables.conf`.

## After the first boot

Provisioning data lies in plain text until you delete it; on Hetzner Cloud and OVHcloud the provider keeps it for the life of the server. Once the appliance has started:

1. Detach the NoCloud drive, or delete the seed files and your file in `/etc/cloud/cloud.cfg.d/`. The settings and secrets stay in effect.
2. Delete provisioning data that holds secrets, such as snippets on Proxmox VE, and remove secret credentials from the VM configuration.

## Expected cloud-init status

```bash
cloud-init status
```

reports `degraded done` and exits with code 2. The cause is the key `kamerplanter:`, which cloud-init doesn't know. This isn't an error; no unit or check of the appliance treats it as one.

!!! warning "Stay within this interface"
    The root file system is immutable and is replaced by every update. cloud-init features beyond this page, such as modules that install packages or write under `/usr`, can interfere with updates and rollbacks.
