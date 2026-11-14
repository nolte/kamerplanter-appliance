# Update and Rollback

Status: draft

## Context

An appliance that the user never administers still has to change: Kamerplanter releases new versions, the base distribution ships security fixes, and the appliance itself evolves. This spec states how such a change reaches an installed appliance, what the self-hoster experiences while it happens, how a failed update is undone, and what the self-hoster can control or has to know. The intended experience is that updates need no action and no attention, and that a failed update leaves the appliance as it was, data included.

`AUDIENCES.md` names the self-hoster as the primary audience. Infrastructure-as-code automation that creates and replaces appliances is a secondary audience of this spec.

Established on 2026-11-13:

- An appliance installed from the current proof of concept cannot update at all. `bootc status` in boot run 1 reports the image reference `localhost/kamerplanter-appliance:poc` as its update source (`.build/boot/run1.measure.txt`), a reference no registry serves.
- The base system updates through bootc: `bootc upgrade` stages a new system image next to the running one and switches on the next boot; the previous deployment stays bootable; `/var` exists once and is not touched by an update or a rollback, while `/etc` is merged per deployment [R1][R2]. The default timer `bootc-fetch-apply-updates.timer` fetches and applies with an immediate reboot, and its documentation expects the schedule to be overridden [R3][R4]. bootc itself rolls back only a deployment that fails to boot; a rollback on a failed health check needs greenboot, which the image does not contain yet [R2][R5].
- The Kamerplanter backend applies database migrations on every start under a lock that expires after 300 seconds (`src/backend/app/migrations/framework/runner.py`, `tracking.py` in `nolte/kamerplanter`). Of the 108 migrations in that working copy, 2 declare themselves reversible; the migration template defaults to `reversible = False` (`src/backend/app/migrations/framework/cli.py`). A previous Kamerplanter version can therefore in general not run on data that a newer version has migrated.
- The container images are pinned by digest in the system image (`image/rootfs/usr/share/containers/systemd/`), so a system image version always starts the Kamerplanter version it was released with.

Decided for the stage 2 prototype on 2026-11-13, after the findings recorded in `spec/distribution-requirements/` (open questions on B3 and B6):

- The appliance checks updates against an update key that ships in the image, because the policy check bootc applies cannot verify the release workflow's keyless identity (`spec/release-distribution/` D8).
- `kamerplanter-update` (`image/rootfs/usr/bin/`) implements discovery, activation in the window, the data backup as a copy of the database volumes, the health check, and the rollback with `bootc rollback`; greenboot is not used, because its boot counter does not reach the GRUB configuration that bootc installs.
- The Kamerplanter container images are logically bound images, pulled into the disk at installation and staged with every update.

Unestablished: whether bootc's logically bound images work with the appliance's Quadlet units and the Anaconda installer path, and how long an update takes on the reference targets. Settling both takes the stage 2 prototype, which is planned but not built.

Boundaries: `spec/distribution-requirements/` §B owns the capabilities the base distribution must provide (atomicity, keeping the previous version, authenticity checks); this spec owns the process built on them and what the self-hoster experiences. `spec/release-distribution/` owns how releases are built, signed, and published; this spec starts where a published release exists. Kamerplanter's own migration rules belong to `nolte/kamerplanter`.

Readers: the maintainer, who implements and releases updates, and the authors of the self-hoster documentation.

## Goals

- An installed appliance stays current without any action by the self-hoster.
- An update never leaves the appliance in a state worse than before: it either completes and passes its health check, or the appliance returns to the previous version with the previous data.
- The self-hoster can see what version runs, what comes next, and what happened during the last update, and can choose when updates activate.
- No reinstallation is ever needed to move to a newer version, including a new major version of the base distribution.

## Non-Goals

- Updating Kamerplanter containers independently of the system image.
- Several update channels with different stability levels; one stable channel is enough for now.
- Updates pushed from a central management service or fleet controller.
- Backing up the appliance's data for disaster recovery; this spec only covers the data protection an update needs.
- Downgrading to an arbitrary older version.

## Requirements

### A. Versions and sources

- **A1 MUST** deliver every update as a complete, published appliance release that carries one system image version, one set of Kamerplanter container images, and one base distribution version.
- **A2 MUST** install each appliance with the registry reference of its release channel as update source, never a local or build-time reference.
- **A3 MUST** offer appliances only releases published through `spec/release-distribution/`; drafts and pull-request builds never reach an installed appliance.
- **A4 MUST** let an update move only forward; a release older than the running one is never offered.
- **A5 MUST** let an appliance update directly from any supported release to the newest one, without intermediate releases that the self-hoster has to install in order.
- **A6 MUST** document for every release whether its update changes data in a way that a rollback cannot undo without restoring a backup.

### B. Discovery and download

- **B1 MUST** check for a new release on its own, at least once a day.
- **B2 MUST** use outbound connections only, so an appliance behind NAT and without port forwarding receives updates.
- **B3 MUST** verify the signature of a new system image against the release workflow's identity before staging it, and discard an image that fails.
- **B4 MUST** stage the new system image and the container images it references completely before the activating reboot, so that the first boot of the new version needs no registry access.
- **B5 MUST** keep the services running unchanged while an update is downloaded and staged.
- **B6 MUST** retry a failed check or download later on its own, without a user action and without blocking the running services.
- **B7 MUST** keep an appliance without internet access running on its current version indefinitely, and update it once access returns.
- **B8 SHOULD** download only the parts of the system image that changed.

### C. Activation

- **C1 MUST** activate a staged update only inside a maintenance window.
- **C2 MUST** ship a default maintenance window that falls into the night of the appliance's configured time zone.
- **C3 MUST** let the self-hoster set the maintenance window in the user configuration file.
- **C4 MUST** activate an update with exactly one reboot.
- **C5 MUST** document the expected interruption of the web UI and the API during activation.
- **C6 SHOULD** let the self-hoster activate a staged update immediately with one documented command.
- **C7 SHOULD** let the self-hoster postpone updates for a limited time, after which they resume on their own.
- **C8 MAY** let the self-hoster hold a specific version.

### D. Data during an update

- **D1 MUST** keep all persistent data, the user configuration, and the generated secrets across an update and across a rollback.
- **D2 MUST**, before the first start of a new version, record a consistent backup of every database the new version may migrate, taken with the services stopped.
- **D3 MUST** restore that backup when the appliance rolls back from a version that has already started against the data; a rollback never runs the previous version on data migrated by the newer one.
- **D4 MUST** keep the backup of D2 until the new version has passed its health check and run without a rollback for a defined period, and delete it afterwards.
- **D5 MUST** refuse to activate an update when the data location lacks space for the backup of D2, and report why.
- **D6 MUST** tell the self-hoster that data written between the update and a rollback is lost with the restore, in the documentation and in the record of D3's rollback.
- **D7 MUST** generate every secret a new version newly requires and keep every existing one, as `spec/distribution-requirements/` D9 and D10 require.

### E. Health check and automatic rollback

- **E1 MUST** define the health of a new version as: the configuration check passes, all core containers report healthy, and the web UI and the API answer, all within a stated time budget after the activating boot.
- **E2 MUST** roll back on its own to the previous version when the new version fails to boot or fails E1.
- **E3 MUST** limit automatic rollback attempts, so that a failure never results in a reboot loop.
- **E4 MUST NOT** retry a version that failed and was rolled back; the appliance waits for a newer release.
- **E5 MUST** record for every update attempt the version, the time, the result, and for a rollback the failed check, readable by the self-hoster afterwards.
- **E6 MUST** treat a first start that legitimately takes long, such as data migrations, as healthy within its time budget and not roll it back early.

### F. Manual rollback

- **F1 MUST** let the self-hoster return to the previous version with one documented command.
- **F2 MUST** apply D2 to D6 to a manual rollback as to an automatic one.
- **F3 MUST** state that only the previous version is available for a rollback.
- **F4 MUST** keep a manually rolled-back version from being updated to the same failed release again, as E4 requires for automatic rollbacks.

### G. Visibility

- **G1 MUST** show the running version, a staged version if any, and the time of the next maintenance window on the console after boot.
- **G2 MUST** provide the same information and the record of E5 through one documented command and in machine-readable form.
- **G3 MUST** publish release notes for every release that name the Kamerplanter version, the base distribution version, configuration changes, and whether a rollback needs a data restore (A6).
- **G4 SHOULD** let the self-hoster learn about a failed update or a rollback without logging in, for example through the web UI or a notification.

### H. Security fixes and support

- **H1 MUST** publish a release that contains a security fix for the base distribution, the container runtime, or a packaged container within a stated time after the fix is available.
- **H2 MUST** let a release that only carries security fixes take the same path as any other release.
- **H3 MUST** state how long a release of the appliance receives updates and what happens when its support ends.
- **H4 MUST** keep an appliance whose release is no longer supported running, and show that state as in G1.

### I. Documentation for the self-hoster

- **I1 MUST** provide a page that explains updates and rollbacks from the self-hoster's point of view: what happens when, what can be configured, what can go wrong, and what to do then.
- **I2 MUST** describe how to read the update record (E5) and how to roll back manually (F1).
- **I3 MUST** explain that an appliance installed from a release before A2 was met does not update and how to move it to an updating one.

## Acceptance Criteria

The criteria roll several requirements together; every requirement stays normative on its own. They are checked by boot runs of the stage 2 prototype.

- [ ] A freshly installed appliance reports the release channel's registry reference as its update source (A2).
- [ ] An appliance installed from release N updates to release N+1 published afterwards, without any action, within one day plus one maintenance window, and runs N+1 healthy afterwards (A1, B1, C1, C4).
- [ ] An appliance installed from release N updates to N+2 without installing N+1 (A5).
- [ ] An update with an image signed by another identity is discarded, and the appliance keeps running its version (B3).
- [ ] During staging the web UI and the API keep answering; the first boot of the new version succeeds with registry access blocked (B4, B5).
- [ ] An appliance without internet access for a week keeps running and updates within a day after access returns (B6, B7).
- [ ] A changed maintenance window in the user configuration file moves the activating reboot into that window (C1, C3).
- [ ] An update to a release whose backend fails its health check ends on the previous release with the data as before the update, and the record names the failed check (D2, D3, E1, E2, E5).
- [ ] An update to a release that migrates the database and then fails its health check ends on the previous release with the backup restored, and the previous release runs healthy (D3).
- [ ] A release that never becomes healthy causes at most the stated number of rollback attempts and is not tried again (E3, E4).
- [ ] An update whose first start takes longer than usual because of migrations, but within its time budget, is not rolled back (E6).
- [ ] With too little free space for the backup, the update is not activated and the reason is recorded (D5).
- [ ] A manual rollback with the documented command restores the previous release and its data, and the failed release is not retried (F1, F2, F4).
- [ ] The console shows running version, staged version, and next window; the documented command returns the same in machine-readable form (G1, G2).
- [ ] The release notes of each release state Kamerplanter version, base version, configuration changes, and whether a rollback needs a restore (A6, G3).
- [ ] The documentation page covers updates, the maintenance window, the update record, manual rollback, data loss on restore, and moving an appliance that does not update (D6, I1, I2, I3).

## References

- Sources retrieved 2026-11-12 during the distribution review recorded in `spec/distribution-requirements/`.
- [R1] bootc documentation, "bootc-upgrades(7)" (P): <https://github.com/bootc-dev/bootc/blob/main/docs/src/bootc-upgrades.7.md>
- [R2] bootc documentation, "bootc-boot-failure-detection(7)" (P): <https://github.com/bootc-dev/bootc/blob/main/docs/src/bootc-boot-failure-detection.7.md>
- [R3] bootc documentation, "bootc-fetch-apply-updates.service(5)" (P): <https://github.com/bootc-dev/bootc/blob/main/docs/src/man/bootc-fetch-apply-updates.service.5.md>
- [R4] Fedora bootc documentation, "Auto-updates" (P): <https://docs.fedoraproject.org/en-US/bootc/auto-updates/>
- [R5] greenboot-rs README (P): <https://github.com/fedora-iot/greenboot-rs/blob/main/README.md>
- [R6] bootc documentation, "bootc-logically-bound-images(7)" (P): <https://github.com/bootc-dev/bootc/blob/main/docs/src/bootc-logically-bound-images.7.md>

## Open Questions

- **Mechanism of the data backup.** The prototype copies the database volumes while the databases are stopped. On ext4 that needs as much free space as the data and takes as long as the copy; for large data a filesystem snapshot or a database dump may be better. Neither the data size on real appliances nor the copy time has been measured.
- **A version that does not reach user space.** E2 also covers a version that fails to boot. The prototype's check runs in user space, and without a boot counter in the GRUB configuration nothing returns from a kernel that hangs. Adding greenboot-rs's GRUB snippet to bootupd's static configuration, or a boot counter of bootc's own, are the candidates.
- **When the previous version is considered safe to drop.** D4 keeps the backup for "a defined period" after a successful update. A day, a week, or until the next update are all plausible; the trade-off is disk space against the chance to notice a late failure.
- **Pre-fetching the container images.** B4 needs the new Kamerplanter images in local storage before the reboot. bootc's logically bound images do this [R6], but their support in the installer path is limited according to the distribution review; whether they work with the appliance's units is unestablished.
- **Default maintenance window and time zone.** C2 places the default window at night in the appliance's time zone, but the appliance has no setup step that asks for a time zone yet.
- **How the self-hoster is told about a failed update.** G4 asks for a way that needs no login. The web UI belongs to Kamerplanter, so a message there needs upstream support; a notification needs a configured channel. Both are undecided.
- **Support period and security response time.** H1 and H3 need concrete numbers. They depend on the maintainer's capacity and on the cadence of the base distribution; while the base is Fedora Rawhide, no stable promise is possible.
- **Release channel naming and the move from the proof of concept.** A2 needs a channel reference such as `ghcr.io/nolte/kamerplanter-appliance:stable`; its name and whether appliances may switch channels are undecided. Appliances installed from proof-of-concept builds need a documented one-time switch (I3).
