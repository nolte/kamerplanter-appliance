---
title: Updates und Rollback
audience: [self-hoster]
content_mode: explanation
track: user-docs
last_updated: 2026-11-15
---

# Updates und Rollback

Die Appliance hält sich selbst aktuell. Du musst nichts tun, aber es hilft zu wissen, was geschieht, was du einstellen kannst und was zu tun ist, wenn ein Update scheitert.

## Was geschieht

1. **Jeden Tag** fragt die Appliance die Registry `ghcr.io/nolte/kamerplanter-appliance`, ob ein neues Release erschienen ist. Sie baut nur Verbindungen nach außen auf; kein Port muss offen sein.
2. Ein neues Release wird **im Hintergrund heruntergeladen**, und seine Signatur wird gegen den Schlüssel geprüft, der in die Appliance eingebaut ist. Ein Release mit fehlender oder falscher Signatur wird verworfen, ebenso ein Release, das älter ist als das laufende. Kamerplanter läuft währenddessen weiter.
3. Im **Wartungsfenster**, standardmäßig nachts zwischen 03:00 und 03:30 Uhr in der Zeit der Appliance, startet sie einmal in das neue Release neu. Web-UI und API sind dabei einige Minuten nicht erreichbar. Alles, was das neue Release braucht, wurde vorher heruntergeladen, auch die Kamerplanter-Container; der Neustart braucht also keinen Internetzugang.
4. Bevor das neue Release deine Daten zum ersten Mal berührt, **kopiert die Appliance die Datenbank**: nach `/var/lib/kamerplanter/update/backup/` auf der Systemplatte oder auf einen [Sicherungs-Datenträger oder Datenträger](#where-the-backup-goes), wenn du einen hast.
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

`kamerplanter-update status --json` gibt dasselbe als JSON aus. Die Konsole zeigt die laufende Version, ein bereitgelegtes Update und das nächste Fenster über der Anmeldung.

## Selbst zum vorherigen Release zurückkehren { #returning-to-the-previous-release-yourself }

Funktioniert ein Release, stimmt aber etwas damit nicht, kehrst du zum vorherigen zurück:

```bash
kamerplanter-update rollback
```

Die Appliance startet in das vorherige Release neu und stellt die Datenbank-Kopie von vor dem Update wieder her; alles, was seit dem Update geschrieben wurde, geht verloren. Zur Verfügung steht nur das Release direkt vor dem aktuellen und nur, solange seine Datenbank-Kopie aufbewahrt wird, standardmäßig 7 Tage. Das verlassene Release wird nicht erneut installiert.

Ist ein [Datenträger](data-disk.md) eingerichtet, lehnt das Kommando die Rückkehr zu einem Release ab, das keine Datenträger kennt: Dieses Release würde den Datenträger übergehen und auf dem laufen, was die Systemplatte darunter hält, einer alten Kopie deiner Daten oder keiner, und neue Secrets erzeugen. Bleib dann beim aktuellen Release. Scheitert ein Update und kehrt die Appliance selbst zurück, lehnt sie nie ab; kennt das Release, zu dem sie zurückkehrt, keine Datenträger, wurde der Datenträger während dieses gescheiterten Updates eingerichtet, und die Appliance kehrt zuerst zur Kopie deiner Daten auf der Systemplatte zurück, die unverändert ist. Der Datenträger wird danach nicht mehr verwendet, bis du ihn erneut benennst, wie nach einem [gescheiterten Umzug](data-disk.md#moving-an-appliance-onto-a-data-disk).

## Einstellungen

Trage sie in `/etc/kamerplanter/kamerplanter.env` ein:

| Einstellung | Standard | Bedeutung |
|---|---|---|
| `UPDATE_WINDOW` | `03:00` | Beginn des Wartungsfensters, `HH:MM` in der Zeit der Appliance; der Neustart erfolgt innerhalb von 30 Minuten danach |
| `UPDATE_HEALTH_TIMEOUT` | `20` | Minuten, die ein neues Release hat, um gesund zu werden; 1 bis 9999 |
| `UPDATE_BACKUP_KEEP_DAYS` | `7` | Tage, die eine Datenbank-Kopie von vor einem Update aufbewahrt wird; mindestens 3, eine kleinere Zahl gilt als 3; höchstens sechs Stellen |

Nach einer Änderung von `UPDATE_WINDOW` führe `systemctl daemon-reload` aus. Die Zeitzone der Appliance ist UTC, solange du keine andere mit `timedatectl set-timezone` einstellst.

Die Datenbank-Kopie braucht Platz: Ein Update wird nicht aktiviert, solange kein Ort für die Kopie freien Platz für die Datenbank plus 10 % und 512 MiB hat; das Protokoll sagt das. Lässt sich die Kopie beim ersten Start des neuen Release trotzdem nicht anlegen, kehrt die Appliance zum vorigen Release zurück, bevor das neue die Daten berührt, und aktiviert das Update in einem späteren Fenster erneut.

## Wohin die Datenbank-Kopie geht { #where-the-backup-goes }

Mit einem [Sicherungs-Datenträger oder Datenträger](data-disk.md) nimmt die Appliance den ersten dieser Orte, der verwendbar ist und Platz hat:

1. den Sicherungs-Datenträger `kp-backup`, in `update-backup/` oben auf der Platte
2. den Datenträger `kp-data`, in `update-backup/` oben auf der Platte
3. die Systemplatte, in `/var/lib/kamerplanter/update/backup/`

Eine Platte wird übergangen, wenn sie nicht eingerichtet ist, fehlt, unter einer anderen Identität eingehängt ist als der, mit der sie eingerichtet wurde, oder zu wenig Platz hat. Mit einem verschlüsselten Datenträger wird auch ein unverschlüsselter Sicherungs-Datenträger übergangen. Das Update-Protokoll nennt den verwendeten Ort und warum die anderen übergangen wurden:

```text
  2026-11-15T03:05:40Z  update  backup  data backed up before the first start of v0.3.0 on the data disk kp-data; not on the backup disk kp-backup: the backup disk kp-backup is missing or not mounted
```

Das erste Update von einem Release, das nur die Systemplatte kennt, legt seine Kopie dort ab, damit ein Rollback auf dieses Release sie findet.

Das Protokoll hält fest, wo jede Kopie liegt, und eine Prüfsumme über die Dateien, ihre Rechte und Besitzer, ihre erweiterten Attribute wie SELinux-Labels und ACLs und ihre Hardlinks. Die Prüfsumme wird vor einer Wiederherstellung geprüft und noch einmal an den wiederhergestellten Daten, bevor die Dienste starten. Fehlt die Platte der Kopie bei einem Rollback oder stimmt die Prüfsumme nicht, wird die Kopie nicht wiederhergestellt, und die Dienste bleiben angehalten; die Konsole und `systemctl status kamerplanter-update-guard.service` sagen warum. Bei einer fehlenden Platte schließe sie wieder an und starte dann neu, oder führe `systemctl restart kamerplanter-backup-disk.service kamerplanter.target` aus. Eine beschädigte Kopie musst du von Hand aus einer anderen Sicherung ersetzen. `kamerplanter-update status` listet jede Kopie mit ihrem Ort. Besteht die Sicherung ihre Prüfung, aber die wiederhergestellten Daten nicht, sind die Volumes bereits ersetzt, die Dienste bleiben angehalten, und beim nächsten Start wird die Sicherung erneut kopiert.

## Den Zeitpunkt wählen

```bash
kamerplanter-update apply-now       # sofort herunterladen und aktivieren
kamerplanter-update postpone 7      # 7 Tage keine Aktivierung (1-30)
kamerplanter-update resume          # Aufschub beenden
```

Ein Aufschub endet von selbst; danach geht es im Fenster mit Updates weiter.

## Eine Appliance, die sich nicht aktualisiert

Eine Appliance, die aus einem Proof-of-Concept-Build vor v0.1.0 installiert wurde, hat keine Registry als Update-Quelle und aktualisiert sich nie. Ihr fehlt das Kommando `kamerplanter-update`, und `bootc status` zeigt einen Image-Namen, der mit `localhost/` beginnt. Installiere stattdessen das aktuelle Release darauf, nachdem du `/etc/kamerplanter/` und die Daten gesichert hast.
