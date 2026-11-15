---
title: Data disk and backup disk
audience: [self-hoster]
content_mode: explanation
track: user-docs
last_updated: 2026-11-15
---

# Data disk and backup disk

By default the appliance keeps everything on one disk, the system disk. You can give it two more, both optional:

- a **data disk** with the label `kp-data`, which holds your configuration, the generated secrets, and the databases
- a **backup disk** with the label `kp-backup`, which receives the database copy taken before each update

With a data disk, the system and your data have separate lives: you can reinstall the system disk, or replace the whole machine, and carry on with the data disk. Without either disk nothing changes; the appliance runs exactly as described in [Updates and rollback](updates.md).

## What lives where

| Disk | Holds |
|---|---|
| System disk | The operating system; the update record and its state in `/var/lib/kamerplanter/update/`; the disk records and the stored keys in `/var/lib/kamerplanter/disks/` |
| Data disk `kp-data` | `/etc/kamerplanter/` (your file `kamerplanter.env` and `secrets.env`); the records in `/var/lib/kamerplanter/pinned/`; the ArangoDB and Valkey volumes; the release marker; pre-update backups when no backup disk takes them |
| Backup disk `kp-backup` | Pre-update backups |

The paths stay the same with a data disk. The appliance mounts it at `/var/mnt/kamerplanter-data` and binds its directories onto `/etc/kamerplanter`, `/var/lib/kamerplanter/pinned`, and the two volumes, so you keep editing `/etc/kamerplanter/kamerplanter.env` as before. The backup disk is mounted at `/var/mnt/kamerplanter-backup`. Both are mounted `nosuid,nodev,noexec`, after a file system check, before any Kamerplanter service starts.

## Choosing a disk

Use a local disk: a second virtual disk, a second internal drive, a USB disk, or a USB stick. Network storage is refused, including network file systems, network block devices, and disks attached over iSCSI or Fibre Channel.

!!! warning "Removable media"
    The data disk carries the generated secrets and the whole database; a backup disk carries a full copy of the database. Whoever takes an unencrypted stick or disk away can read both. [Encrypt](#encryption) a disk that can leave the premises.

    A database writes constantly. A USB stick wears out under this and can lose data on a power cut; prefer a USB disk or SSD. For a hosted VM, a second disk is stored by the provider like the first.

## Setting up a disk

A disk is used only when you name it explicitly, by a path under `/dev/disk/by-id/` or `/dev/disk/by-uuid/`. Find the path with:

```bash
ls -l /dev/disk/by-id/
```

Name it in one of two ways:

- **In your file** `/etc/kamerplanter/kamerplanter.env`, on an appliance that runs already:

    ```ini
    DATA_DISK=/dev/disk/by-id/usb-Example_Disk_0123456789-0:0
    BACKUP_DISK=/dev/disk/by-id/ata-Example_SSD_ABC123
    ```

- **As a system credential** `kamerplanter.data-disk` or `kamerplanter.backup-disk` from the provisioner, before the first boot. See [Provisioning](#provisioning).

When both name the data disk differently, the appliance uses neither. One disk can't be named as data disk and as backup disk at once.

What happens to the named disk:

| The disk | Result |
|---|---|
| is blank | Formatted ext4 with the label `kp-data` or `kp-backup` |
| carries an ext4 file system with that label already | Used as it is |
| carries another file system or a partition table | Refused; the message names what it found. `DATA_DISK_FORCE=1` or `BACKUP_DISK_FORCE=1` (credential `kamerplanter.data-disk-force`, `kamerplanter.backup-disk-force`) formats it anyway, once for that path |
| holds the running system, is mounted or in use, or isn't a local disk | Always refused, also when forced |

A disk that appears late, such as a USB disk, gets 30 seconds. Once set up, the disk is recorded in `/var/lib/kamerplanter/disks/` on the system disk together with its UUID. On every boot it's found by its label and accepted only under that UUID. A second device with the same label, for example a cloned stick, keeps the services stopped until you remove it.

A naming takes effect when the disk service starts: at the next boot, or at once with `systemctl restart kamerplanter-data-disk.service` for a data disk. For a data disk on an appliance that holds data already, read [Moving an appliance onto a data disk](#moving-an-appliance-onto-a-data-disk) first.

## Checking the disks

```bash
/usr/libexec/kamerplanter/disks status
```

```text
data disk: kp-data, UUID 0b9e6a52-4c1d-4f3e-9a57-2d1c8e7f6a10, mounted at /var/mnt/kamerplanter-data from /dev/sdb
  not encrypted
  release marker: 0.3.0
  /etc/kamerplanter: on the disk (etc)
  /var/lib/kamerplanter/pinned: on the disk (pinned)
  /var/lib/containers/storage/volumes/arangodb_data: on the disk (volumes/arangodb_data)
  /var/lib/containers/storage/volumes/valkey_data: on the disk (volumes/valkey_data)
backup disk: not set up
```

`kamerplanter-update status` shows the data disk and its release marker, the state of a move, and where each pre-update backup is. Every set-up, key operation, and step of a move is also recorded in `/var/lib/kamerplanter/disks/log.jsonl`. To recognise a disk on another machine, look for its label:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL
```

## Moving an appliance onto a data disk

An appliance that already holds data on its system disk moves it onto a newly named data disk once:

1. Attach a blank disk. A disk that holds nothing but `lost+found`, or the disk of an earlier move of this appliance, works as well; a disk that holds data of its own is refused, since one of the two would be lost.
2. Name it in `/etc/kamerplanter/kamerplanter.env` as `DATA_DISK=…`.
3. Run:

    ```bash
    systemctl restart kamerplanter-data-disk.service
    ```

    This stops the services, copies the data, and starts them again from the disk. If a service stays stopped afterwards, run `systemctl start kamerplanter.target`. A reboot does the same. `systemctl restart kamerplanter.target` alone doesn't, because it doesn't restart the disk service.

The appliance copies `/etc/kamerplanter`, the records, and both volumes onto the disk, compares the copy, and syncs it before it uses the disk. The disk needs room for the data plus 10 % and 32 MiB; with less, the move is abandoned and the services start from the system disk. After a power cut during the copy, the appliance still runs from the system disk and copies again.

The services then have to pass the same health check as after an update. The copy on the system disk is kept until they have, and for `UPDATE_BACKUP_KEEP_DAYS` days after; then it's deleted. If they fail the check, the appliance returns to the copy on the system disk and stops using the disk.

The record of the move has these states, shown by `/usr/libexec/kamerplanter/disks status` and `kamerplanter-update status`:

| State | Meaning |
|---|---|
| `copying` | The copy is being made; the system disk is still in use |
| `moved` | The copy is complete; the services run from the disk, and the health check is pending |
| `verified` | The services passed the health check from the disk; the copy on the system disk is deleted after the keeping period |
| `cleaned` | The copy on the system disk is deleted |
| `falling-back` | The services failed the health check; the appliance is returning to the copy on the system disk |
| `failed` | The data is on the system disk again; the disk isn't set up |

After a failed move the same naming is ignored, so the appliance doesn't try again on every boot. To try again, remove the naming, reboot once (or run `systemctl restart kamerplanter-data-disk.service`), then name the disk again.

## A new system with an existing data disk

When you reinstall the system disk or replace the machine, attach the data disk and name it as a **credential** for the first boot. Your file `kamerplanter.env` lies on the data disk, so it can't name the disk to a fresh system. The fresh appliance then uses the configuration, secrets, and data from the disk and generates only secrets the disk doesn't hold yet; logins and encrypted fields keep working.

Name the disk before the first boot. Otherwise the first boot generates new secrets on the system disk, and the data disk is then refused because it holds data of its own. An unnamed disk is never used just because it carries the label `kp-data`.

## When the data disk is missing

When a data disk is set up but absent, the services stay stopped. The appliance generates no secrets and writes nothing to the system disk in its place. The same applies when the disk can't be unlocked, carries the label under another UUID, or shares its label with a second device.

The reason is in the journal:

```bash
systemctl status kamerplanter-data-disk.service
```

```text
data disk kp-data is missing
attach it (file system UUID 0b9e6a52-4c1d-4f3e-9a57-2d1c8e7f6a10), then run: systemctl restart kamerplanter.target
```

`kamerplanter-update status` reports the data disk as not in place. Plug the disk back in, then run `systemctl restart kamerplanter.target`, or reboot.

A missing backup disk stops nothing: the pre-update backup goes to the next location.

## An older release on a newer data disk

The data disk carries a release marker: the highest release whose services passed the health check on it. A newer Kamerplanter may have migrated the data in a way an older one can't read. So an older release, and any development build, keeps the services stopped on a disk marked by a newer release. A marker that can't be read refuses every release. A rollback by the appliance isn't affected, since it restores the marker together with the data.

The message names both releases, in `systemctl status kamerplanter-update-guard.service` and in the recent events of `kamerplanter-update status`. Return to the newer release, or restore a backup from before it. To run the older release on the disk all the same, at the risk of data the newer one has migrated, run as root:

```bash
kamerplanter-update allow-downgrade <disk release> <running release>
```

for example `kamerplanter-update allow-downgrade 0.3.0 0.2.0`. A development build shows a running release such as `dev`; copy both values from the message. On a terminal the command asks for confirmation. It holds only for that pair of releases, is recorded in the update record, and starts the services.

## Encryption

A data disk or backup disk can be encrypted with LUKS2 when it's formatted. Supply a key for a blank disk, or one formatted with `…_FORCE=1`. A disk set up unencrypted is never encrypted afterwards.

The key comes from you or your provisioner; the appliance never generates one, and there is no setting for it in `kamerplanter.env`, which lies on the data disk. Supply it as:

- the system credential `kamerplanter.data-disk-key` or `kamerplanter.backup-disk-key`, or
- the file of that name in `/var/lib/kamerplanter/disks/keys/`, owned by root with mode 0600.

A key holds 32 to 8192 bytes and is taken byte for byte, a trailing line break included.

Once the disk is set up, the appliance keeps the key on the system disk in `/var/lib/kamerplanter/disks/keys/` (root, 0600, directory 0700) and opens the disk with it on every boot. It deletes the copies it was given: the key file, and the credential in `/etc/credstore/` or `/run/credstore/`. A credential from the firmware or the kernel command line lives only in memory. The key never appears in a message, the journal, or the update record. When the disk is no longer set up, the stored key is deleted.

Keep a copy of the key off the appliance: a new system needs it to open the disk.

The services stay stopped when:

- a key is supplied for a disk set up unencrypted; remove the key
- an encrypted disk has no key, or no key that opens it
- two different keys are supplied for a disk that is to be formatted
- a backup disk is named without a key while the data disk is encrypted

Unlocking takes time: about 3 seconds on 2 virtual CPUs, longer on small hardware.

!!! warning "What encryption protects against"
    A key kept on the system disk protects against the loss of the data disk alone, not against the loss of the whole machine. With an encrypted data disk, a backup disk is used only when it's encrypted as well; an unencrypted one is skipped, and the backup goes to the next location.

## Where the pre-update backup goes

The backup goes to the backup disk, else to the data disk, else to the system disk. When a location is missing, too small, or not usable, the next one takes the backup, and the update record says which one and why. See [Updates and rollback](updates.md#where-the-backup-goes).

## Provisioning

A provisioner, such as a Terraform module, passes these as systemd credentials, for example as SMBIOS type 11 strings of a VM. Name the disks by a `/dev/disk/by-id/` or `/dev/disk/by-uuid/` path that's stable inside the guest:

| Credential | Value |
|---|---|
| `kamerplanter.data-disk` | Path of the data disk |
| `kamerplanter.data-disk-force` | `1` to format a data disk that carries other signatures, once |
| `kamerplanter.data-disk-key` | Key of the data disk, 32 to 8192 bytes; makes a blank disk encrypted |
| `kamerplanter.backup-disk` | Path of the backup disk |
| `kamerplanter.backup-disk-force` | `1` to format a backup disk that carries other signatures, once |
| `kamerplanter.backup-disk-key` | Key of the backup disk |

For QEMU, a data disk with the serial `kpdata` appears as `/dev/disk/by-id/virtio-kpdata`:

```bash
-drive if=none,id=data,file=data.qcow2,format=qcow2 \
-device virtio-blk-pci,drive=data,serial=kpdata \
-smbios type=11,value=io.systemd.credential:kamerplanter.data-disk=/dev/disk/by-id/virtio-kpdata
```

A binary key goes in base64 as `io.systemd.credential.binary:kamerplanter.data-disk-key=…`.

## Retiring a disk

Deleted files may remain readable on the medium, also the copy on the system disk after a move. Wipe or destroy a disk before it leaves your hands.

- **Backup disk:** remove the naming, delete `/var/lib/kamerplanter/disks/backup.env`, and reboot. The stored key of the disk is deleted then. Backups on that disk can no longer be restored.
- **Data disk:** this release has no way to move the data back to the system disk or onto another data disk; while a data disk is set up, a different naming is ignored. Don't delete `/var/lib/kamerplanter/disks/data.env` while your data is on the disk: without it, the appliance no longer uses that disk.
