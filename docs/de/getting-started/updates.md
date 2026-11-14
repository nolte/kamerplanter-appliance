---
title: Updates und Rollback
audience: [self-hoster]
content_mode: explanation
track: user-docs
last_updated: 2026-11-13
---

# Updates und Rollback

Die Appliance hält sich selbst aktuell. Du musst nichts tun, aber es hilft zu wissen, was geschieht, was du einstellen kannst und was zu tun ist, wenn ein Update scheitert.

## Was geschieht

1. **Jeden Tag** fragt die Appliance die Registry `ghcr.io/nolte/kamerplanter-appliance`, ob ein neues Release erschienen ist. Sie baut nur Verbindungen nach außen auf; kein Port muss offen sein.
2. Ein neues Release wird **im Hintergrund heruntergeladen**, und seine Signatur wird gegen den Schlüssel geprüft, der in die Appliance eingebaut ist. Ein Release mit fehlender oder falscher Signatur wird verworfen. Kamerplanter läuft währenddessen weiter.
3. Im **Wartungsfenster**, standardmäßig nachts zwischen 03:00 und 03:30 Uhr in der Zeit der Appliance, startet sie einmal in das neue Release neu. Web-UI und API sind dabei einige Minuten nicht erreichbar. Alles, was das neue Release braucht, wurde vorher heruntergeladen, auch die Kamerplanter-Container; der Neustart braucht also keinen Internetzugang.
4. Bevor das neue Release deine Daten zum ersten Mal berührt, **kopiert die Appliance die Datenbank** nach `/var/lib/kamerplanter/update/backup/`.
5. Das neue Release hat 20 Minuten, um **gesund** zu werden: Die Konfigurationsprüfung besteht, jeder Container meldet sich gesund, und Web-UI und API antworten. Dann gilt das Update als abgeschlossen.

Das Update ersetzt System und Kamerplanter-Version gemeinsam. Deine Einstellungen in `/etc/kamerplanter/kamerplanter.env`, die erzeugten Geheimnisse und deine Daten bleiben, wie sie sind.

Eine Appliance ohne Internetzugang läuft mit ihrer Version weiter und aktualisiert sich, sobald sie wieder online ist.

## Wenn ein Update scheitert

Wird das neue Release nicht rechtzeitig gesund, **kehrt die Appliance selbst zum vorherigen Release zurück**, startet noch einmal neu und **stellt die Datenbank-Kopie** von vor dem Update wieder her. Ein gescheitertes Release wird nie erneut versucht; die Appliance wartet auf das nächste.

!!! warning "Nach dem Update geschriebene Daten"
    Die Wiederherstellung setzt die Daten auf ihren Stand vor dem Update zurück. Was zwischen Update und Rückkehr geschrieben wurde, nach einer automatischen Rückkehr höchstens die 20 Minuten der Prüfung, geht verloren.

Was geschehen ist, wird festgehalten. Anzeigen lässt es sich mit:

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

`kamerplanter-update status --json` gibt dasselbe als JSON aus. Die Konsole zeigt die laufende Version und das nächste Fenster über der Anmeldung.

## Selbst zum vorherigen Release zurückkehren

Funktioniert ein Release, stimmt aber etwas damit nicht, kehrst du zum vorherigen zurück:

```bash
kamerplanter-update rollback
```

Die Appliance startet in das vorherige Release neu und stellt die Datenbank-Kopie von vor dem Update wieder her; alles, was seit dem Update geschrieben wurde, geht verloren. Zur Verfügung steht nur das Release direkt vor dem aktuellen und nur, solange seine Datenbank-Kopie aufbewahrt wird, standardmäßig 7 Tage. Das verlassene Release wird nicht erneut installiert.

## Einstellungen

Trage sie in `/etc/kamerplanter/kamerplanter.env` ein:

| Einstellung | Standard | Bedeutung |
|---|---|---|
| `UPDATE_WINDOW` | `03:00` | Beginn des Wartungsfensters, `HH:MM` in der Zeit der Appliance; der Neustart erfolgt innerhalb von 30 Minuten danach |
| `UPDATE_HEALTH_TIMEOUT` | `20` | Minuten, die ein neues Release hat, um gesund zu werden |
| `UPDATE_BACKUP_KEEP_DAYS` | `7` | Tage, die eine Datenbank-Kopie von vor einem Update aufbewahrt wird |

Nach einer Änderung von `UPDATE_WINDOW` führe `systemctl daemon-reload` aus. Die Zeitzone der Appliance ist UTC, solange du keine andere mit `timedatectl set-timezone` einstellst.

Die Datenbank-Kopie braucht Platz: Ein Update wird nicht aktiviert, solange `/var` weniger freien Platz hat als die Datenbank plus einen Puffer; das Protokoll sagt das.

## Den Zeitpunkt wählen

```bash
kamerplanter-update apply-now       # sofort herunterladen und aktivieren
kamerplanter-update postpone 7      # 7 Tage keine Aktivierung (1-30)
kamerplanter-update resume          # Aufschub beenden
```

Ein Aufschub endet von selbst; danach geht es im Fenster mit Updates weiter.

## Eine Appliance, die sich nicht aktualisiert

Eine Appliance, die aus einem Proof-of-Concept-Build vor v0.1.0 installiert wurde, hat keine Registry als Update-Quelle und aktualisiert sich nie. Ihr fehlt das Kommando `kamerplanter-update`, und `bootc status` zeigt einen Image-Namen, der mit `localhost/` beginnt. Installiere stattdessen das aktuelle Release darauf, nachdem du `/etc/kamerplanter/` und die Daten gesichert hast.
