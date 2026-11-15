---
title: Erste Schritte
audience: [maintainer]
content_mode: tutorial
track: developer-docs
last_updated: 2026-11-15
---

# Erste Schritte

Diese Seite führt durch den Bau des Proof of Concept und seinen Start in einer lokalen virtuellen Maschine.

## Voraussetzungen

- Docker, und dein Benutzer darf Container starten
- Zugriff auf `/dev/kvm`
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

## Die Appliance betreiben

- [Updates und Rollback](updates.md) — wie sich die Appliance selbst aktualisiert und zum vorherigen Release zurückkehrt
- [Datenträger und Sicherungs-Datenträger](data-disk.md) — Daten und die Sicherungen vor Updates auf eigenen lokalen Platten halten

## Aufräumen

```bash
task clean
```
