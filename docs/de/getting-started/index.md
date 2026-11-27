---
title: Erste Schritte
audience: [maintainer]
content_mode: tutorial
track: developer-docs
last_updated: 2026-11-17
---

# Erste Schritte

Diese Seite führt durch den Bau des Proof of Concept und seinen Start in einer lokalen virtuellen Maschine.

## Voraussetzungen

- Docker, und dein Benutzer darf Container starten
- Zugriff auf `/dev/kvm`, nur für die Boot-Tests (`task test:boot`)
- [Task](https://taskfile.dev)
- Etwa 20 GB freier Plattenplatz und 6 GB freier Arbeitsspeicher

Jeder Bau- und Testschritt läuft in einem privilegierten Werkzeug-Container, der podman, die bootc-Werkzeuge und QEMU mitbringt. Auf deinem Rechner wird darüber hinaus nichts installiert.

## Bauen und booten

```bash
task tools:build   # Werkzeug-Container: podman, image-builder, QEMU
task image:build   # System-Image der Appliance
task disk:build    # Raw-Disk-Image aus dem System-Image
task test:boot     # das Disk-Image unter verschiedener Firmware und Hardware booten
task disk:package  # komprimiertes Disk-Image und Prüfsummen in .build/dist/
```

`task test:boot` gibt je Lauf eine Zeile aus und legt die serielle Konsole und eine Diagnose jedes gescheiterten Laufs unter `.build/boot/` ab. Der erste Start jedes Laufs lädt die Container-Images aus ihren Registries und dauert mehrere Minuten.

Die VM-Tests (`task test:boot`, `task test:update`, `task test:data-disk`) laufen auch auf GitHub Actions, verteilt auf parallele Jobs, über den Workflow `vm-tests`: in einem Pull Request, sobald er das Label `vm-tests` trägt (und erneut bei jedem Push, der das Label gesetzt vorfindet), nach jedem Merge nach `develop`, der `image/`, `build/` oder `tests/boot/` ändert, und von Hand unter **Actions → vm-tests → Run workflow**. Die Zusammenfassung des Laufs listet jedes Ergebnis; die Ergebnisdateien und seriellen Konsolen hängen am Lauf.

Das Label ist die Zustimmung, die Testskripte des Pull Requests auszuführen (ein Maintainer setzt es; Renovate setzt es auf seinen eigenen Aktualisierungen des Basis-Images), und es gilt für den Commit, auf dem es gesetzt wurde. Ein Label, das weniger als 5 Minuten nach dem Push eines anderen auf diesen Commit oder nach dem Wiederöffnen des Pull Requests gesetzt wird, wird wieder entfernt, und `vm-gate` schlägt mit einem entsprechenden Hinweis fehl: Die Seite, von der aus es gesetzt wurde, hat möglicherweise noch den Commit davor gezeigt. Die VM-Tests, die das Label gestartet hat, laufen für diesen Commit trotzdem einmal, ihr Ergebnis zählt aber nicht. Den Head erneut ansehen und das Label noch einmal setzen; es zählt ab 5 Minuten nach dem Push. Wer den Commit selbst auf einen Branch dieses Repositorys gepusht hat (Renovate auf seinen eigenen Pull Requests oder `gh pr create --label vm-tests` direkt nach dem Push), kann das Label sofort setzen. Ein Push, der `.github/workflows/vm-tests.yml`, `build/`, `tests/boot/` oder `tests/image/` ändert, und jeder Push auf einen Pull Request aus einem Fork entfernt das Label: Der erforderliche Status `vm-gate` schlägt dann fehl, bis ein Maintainer den neuen Commit angesehen hat und das Label erneut setzt. Der Lauf, den ein solcher Push gestartet hat, läuft trotzdem zu Ende, sein Ergebnis zählt aber nicht, solange das Label fehlt: Erst das erneute Setzen des Labels lässt ein Ergebnis dieses Commits zählen. Ein Push, der nur andere Pfade ändert, behält das Label, es sei denn, `vm-gate` hat den Commit davor nie akzeptiert (zwei Pushes kurz hintereinander). Auch das Wiederöffnen eines Pull Requests behält das Label. Ein Head, der gepusht wurde, während der Pull Request geschlossen war, hat allerdings kein Testergebnis: `vm-gate` schlägt darauf fehl, bis jemand das Label entfernt und erneut setzt, und ein weiterer Push davor entfernt das Label.

## Die Appliance betreiben

- [Updates und Rollback](updates.md) — wie sich die Appliance selbst aktualisiert und zum vorherigen Release zurückkehrt
- [Datenträger und Sicherungs-Datenträger](data-disk.md) — Daten und die Sicherungen vor Updates auf eigenen lokalen Platten halten

## Aufräumen

```bash
task clean
```
