---
title: Datenträger und Sicherungs-Datenträger
audience: [self-hoster]
content_mode: explanation
track: user-docs
last_updated: 2026-11-15
---

# Datenträger und Sicherungs-Datenträger

Standardmäßig hält die Appliance alles auf einer Platte, der Systemplatte. Du kannst ihr zwei weitere geben, beide optional:

- einen **Datenträger** mit dem Label `kp-data`, der deine Konfiguration, die erzeugten Secrets und die Datenbanken aufnimmt
- einen **Sicherungs-Datenträger** mit dem Label `kp-backup`, der die Datenbank-Kopie vor jedem Update aufnimmt

Mit einem Datenträger haben System und Daten getrennte Lebenszyklen: Du kannst die Systemplatte neu installieren oder die ganze Maschine ersetzen und mit dem Datenträger weitermachen. Ohne einen der beiden ändert sich nichts; die Appliance läuft genau wie unter [Updates und Rollback](updates.md) beschrieben.

## Was wo liegt

| Platte | Enthält |
|---|---|
| Systemplatte | Das Betriebssystem; das Update-Protokoll und seinen Zustand in `/var/lib/kamerplanter/update/`; die Datenträger-Aufzeichnungen und die gespeicherten Schlüssel in `/var/lib/kamerplanter/disks/` |
| Datenträger `kp-data` | `/etc/kamerplanter/` (deine Datei `kamerplanter.env` und `secrets.env`); die Aufzeichnungen in `/var/lib/kamerplanter/pinned/`; die Volumes von ArangoDB und Valkey; die Release-Markierung; Datenbank-Kopien vor Updates, wenn kein Sicherungs-Datenträger sie aufnimmt |
| Sicherungs-Datenträger `kp-backup` | Datenbank-Kopien vor Updates |

Die Pfade bleiben mit einem Datenträger dieselben. Die Appliance hängt ihn unter `/var/mnt/kamerplanter-data` ein und bindet seine Verzeichnisse auf `/etc/kamerplanter`, `/var/lib/kamerplanter/pinned` und die beiden Volumes, sodass du `/etc/kamerplanter/kamerplanter.env` wie bisher bearbeitest. Der Sicherungs-Datenträger wird unter `/var/mnt/kamerplanter-backup` eingehängt. Beide werden nach einer Dateisystemprüfung mit `nosuid,nodev,noexec` eingehängt, bevor ein Kamerplanter-Dienst startet.

## Eine Platte wählen

Nimm eine lokale Platte: eine zweite virtuelle Platte, ein zweites internes Laufwerk, eine USB-Platte oder einen USB-Stick. Netzwerkspeicher wird abgelehnt, auch Netzwerk-Dateisysteme, Netzwerk-Blockgeräte und Platten, die über iSCSI oder Fibre Channel angebunden sind.

!!! warning "Wechselmedien"
    Der Datenträger trägt die erzeugten Secrets und die ganze Datenbank; ein Sicherungs-Datenträger trägt eine vollständige Kopie der Datenbank. Wer einen unverschlüsselten Stick oder eine unverschlüsselte Platte mitnimmt, kann beides lesen. [Verschlüssele](#encryption) eine Platte, die das Haus verlassen kann.

    Eine Datenbank schreibt ständig. Ein USB-Stick nutzt sich dabei ab und kann bei einem Stromausfall Daten verlieren; nimm lieber eine USB-Platte oder SSD. Bei einer gehosteten VM speichert der Anbieter eine zweite Platte genauso wie die erste.

## Eine Platte einrichten { #setting-up-a-disk }

Eine Platte wird nur verwendet, wenn du sie ausdrücklich benennst, über einen Pfad unter `/dev/disk/by-id/` oder `/dev/disk/by-uuid/`. Den Pfad findest du mit:

```bash
ls -l /dev/disk/by-id/
```

Benenne sie auf einem dieser Wege:

- **Auf der Systemplatte**, auf einer Appliance, die bereits läuft, als root:

    ```bash
    /usr/libexec/kamerplanter/disks name data /dev/disk/by-id/usb-Example_Disk_0123456789-0:0
    /usr/libexec/kamerplanter/disks name backup /dev/disk/by-id/ata-Example_SSD_ABC123
    ```

    Das schreibt `/var/lib/kamerplanter/disks/naming.env` (root, 0600), die du auch von Hand als `DATA_DISK=…` und `BACKUP_DISK=…` bearbeiten kannst. `disks name backup none` entfernt eine Benennung; ein schon eingerichteter Sicherungs-Datenträger bleibt in Gebrauch, bis du [ihn außer Dienst stellst](#retiring-a-disk).

- **In deiner Datei** `/etc/kamerplanter/kamerplanter.env` als `DATA_DISK=…` oder `BACKUP_DISK=…`, aber nur, solange kein Datenträger eingerichtet ist. Ist einer eingerichtet, liegt diese Datei auf dem Datenträger, und wer die Platte in den Händen hatte, kann sie geändert haben. Deshalb ignoriert die Appliance dann `DATA_DISK`, `BACKUP_DISK` und ihre `…_FORCE` in dieser Datei und sagt das in `systemctl status kamerplanter-data-disk`; benenne den Sicherungs-Datenträger dann mit `disks name`. Kopiert die Appliance deine Datei auf den Datenträger, kommentiert sie diese Zeilen dort aus, und die Konfigurationsprüfung prüft sie in der Datei auf dem Datenträger nicht, sodass sie die Dienste nie angehalten lassen.

- **Als System-Credential** `kamerplanter.data-disk` oder `kamerplanter.backup-disk` vom Provisioner, vor dem ersten Start. Siehe [Provisionierung](#provisioning).

Benennen zwei dieser Wege den Datenträger unterschiedlich, verwendet die Appliance keinen davon. Eine Platte kann nicht zugleich als Datenträger und als Sicherungs-Datenträger benannt werden.

Was mit der benannten Platte geschieht:

| Die Platte | Ergebnis |
|---|---|
| ist leer | Wird als ext4 mit dem Label `kp-data` oder `kp-backup` formatiert |
| trägt bereits ein ext4-Dateisystem mit diesem Label | Wird verwendet, wie sie ist |
| trägt ein anderes Dateisystem oder eine Partitionstabelle | Wird abgelehnt; die Meldung nennt, was gefunden wurde. `disks name data PFAD force` (in der Benennungsdatei `DATA_DISK_FORCE=1` oder `BACKUP_DISK_FORCE=1`; Credential `kamerplanter.data-disk-force`, `kamerplanter.backup-disk-force`) formatiert sie trotzdem, einmal je Gerät: Ein anderer Pfad zur selben Platte formatiert sie nicht erneut. Das Gerät wird über seine WWN oder Seriennummer vermerkt; eine Platte, die keins von beidem meldet, über ihre Gerätenummer, die sich nach einem Neustart ändern kann |
| trägt das laufende System, ist eingehängt oder in Gebrauch, oder ist keine lokale Platte | Wird immer abgelehnt, auch erzwungen |

Bevor sie löscht, verschlüsselt oder formatiert, sperrt die Appliance die Platte und prüft erneut, dass es noch die benannte Platte ist und sie hält, was sie hielt. Ein Kartenleser behält Namen, Gerätenummer und Seriennummer, wenn du seine Karte tauschst; zwei Karten darin unterscheidet die Appliance daher nur an dem, was sie halten: Tausche die Karte nicht, während der Datenträger eingerichtet wird. Ein erzwungenes Formatieren gilt einmal je Kartenleser, nicht je Karte.

Eine Platte, die spät erscheint, etwa eine USB-Platte, bekommt 30 Sekunden. Einmal eingerichtet, wird die Platte samt ihrer UUID in `/var/lib/kamerplanter/disks/` auf der Systemplatte vermerkt. Bei jedem Start wird sie über ihr Label gefunden und nur unter dieser UUID angenommen. Ein zweites Gerät mit demselben Label, zum Beispiel ein geklonter Stick, hält die Dienste angehalten, bis du es entfernst.

Eine Benennung wirkt, wenn der Datenträger-Dienst startet: beim nächsten Start oder für einen Datenträger sofort mit `systemctl restart kamerplanter-data-disk.service`. Für einen Datenträger auf einer Appliance, die bereits Daten hält, lies zuerst [Eine Appliance auf einen Datenträger umziehen](#moving-an-appliance-onto-a-data-disk).

## Die Platten prüfen

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

`kamerplanter-update status` zeigt den Datenträger und seine Release-Markierung, den Stand eines Umzugs und wo jede Datenbank-Kopie vor einem Update liegt. Jede Einrichtung, jeder Schritt mit einem Schlüssel und jeder Schritt eines Umzugs wird außerdem in `/var/lib/kamerplanter/disks/log.jsonl` festgehalten. Um eine Platte an einer anderen Maschine wiederzuerkennen, sieh nach ihrem Label:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL
```

## Eine Appliance auf einen Datenträger umziehen { #moving-an-appliance-onto-a-data-disk }

Eine Appliance, die bereits Daten auf ihrer Systemplatte hält, zieht sie einmalig auf einen neu benannten Datenträger um:

1. Schließe eine leere Platte an. Eine Platte, die nichts als `lost+found` hält, oder die Platte eines früheren Umzugs dieser Appliance geht ebenso; eine Platte mit eigenen Daten wird abgelehnt, da eins von beidem verloren ginge.
2. Benenne sie mit `/usr/libexec/kamerplanter/disks name data /dev/disk/by-id/…` oder in `/etc/kamerplanter/kamerplanter.env` als `DATA_DISK=…`.
3. Führe aus:

    ```bash
    systemctl restart kamerplanter-data-disk.service
    ```

    Das hält die Dienste an, kopiert die Daten und startet die Dienste vom Datenträger aus wieder. Bleibt danach ein Dienst angehalten, führe `systemctl start kamerplanter.target` aus. Ein Neustart der Maschine bewirkt dasselbe. `systemctl restart kamerplanter.target` allein genügt nicht, weil es den Datenträger-Dienst nicht neu startet.

Die Appliance kopiert `/etc/kamerplanter`, die Aufzeichnungen und beide Volumes auf den Datenträger, vergleicht die Kopie und schreibt sie fest, bevor sie den Datenträger verwendet. Der Datenträger braucht Platz für die Daten plus 10 % und 32 MiB; mit weniger wird der Umzug abgebrochen, und die Dienste starten von der Systemplatte. Nach einem Stromausfall während des Kopierens läuft die Appliance weiter von der Systemplatte und kopiert erneut.

Danach müssen die Dienste dieselbe Gesundheitsprüfung bestehen wie nach einem Update. Die Kopie auf der Systemplatte bleibt, bis sie bestanden ist, und danach noch `UPDATE_BACKUP_KEEP_DAYS` Tage (mindestens 3); dann wird sie gelöscht. Fallen die Dienste durch die Prüfung, kehrt die Appliance zur Kopie auf der Systemplatte zurück und verwendet den Datenträger nicht mehr. Dasselbe tut sie, wenn im selben Start ein Update scheitert und die Appliance selbst zu einem Release zurückkehrt, das keine Datenträger kennt; siehe [Updates und Rollback](updates.md#returning-to-the-previous-release-yourself).

Die Aufzeichnung des Umzugs hat diese Zustände, angezeigt von `/usr/libexec/kamerplanter/disks status` und `kamerplanter-update status`:

| Zustand | Bedeutung |
|---|---|
| `copying` | Die Kopie wird angelegt; die Systemplatte ist noch in Gebrauch |
| `moved` | Die Kopie ist vollständig; die Dienste laufen vom Datenträger, die Gesundheitsprüfung steht aus |
| `verified` | Die Dienste haben die Gesundheitsprüfung vom Datenträger aus bestanden; die Kopie auf der Systemplatte wird nach der Aufbewahrungsfrist gelöscht |
| `cleaned` | Die Kopie auf der Systemplatte ist gelöscht |
| `falling-back` | Die Dienste sind durch die Gesundheitsprüfung gefallen; die Appliance kehrt zur Kopie auf der Systemplatte zurück |
| `failed` | Die Daten liegen wieder auf der Systemplatte; der Datenträger ist nicht eingerichtet |

Nach einem gescheiterten Umzug wird dieselbe Benennung übergangen, damit die Appliance es nicht bei jedem Start erneut versucht. Für einen neuen Versuch entferne die Benennung, starte einmal neu (oder führe `systemctl restart kamerplanter-data-disk.service` aus) und benenne die Platte dann erneut.

## Ein neues System mit einem vorhandenen Datenträger

Installierst du die Systemplatte neu oder ersetzt die Maschine, schließe den Datenträger an und benenne ihn für den ersten Start als **Credential**. Deine Datei `kamerplanter.env` liegt auf dem Datenträger und kann ihn einem frischen System daher nicht nennen. Die frische Appliance verwendet dann Konfiguration, Secrets und Daten vom Datenträger und erzeugt nur Secrets, die der Datenträger noch nicht hält; Anmeldungen und verschlüsselte Felder funktionieren weiter.

Benenne den Datenträger vor dem ersten Start. Sonst erzeugt der erste Start neue Secrets auf der Systemplatte, und der Datenträger wird danach abgelehnt, weil er eigene Daten hält. Eine unbenannte Platte wird nie verwendet, nur weil sie das Label `kp-data` trägt.

## Wenn der Datenträger fehlt

Ist ein Datenträger eingerichtet, aber nicht vorhanden, bleiben die Dienste angehalten. Die Appliance erzeugt keine Secrets und schreibt an seiner Stelle nichts auf die Systemplatte. Dasselbe gilt, wenn sich der Datenträger nicht entsperren lässt, das Label unter einer anderen UUID trägt oder sein Label mit einem zweiten Gerät teilt.

Der Grund steht auf der Konsole über der Anmeldung und im Journal:

```bash
systemctl status kamerplanter-data-disk.service
```

```text
data disk kp-data is missing
attach it (file system UUID 0b9e6a52-4c1d-4f3e-9a57-2d1c8e7f6a10), then run: systemctl restart kamerplanter.target
```

`kamerplanter-update status` meldet den Datenträger als nicht eingehängt (`not in place`). Stecke die Platte wieder an und führe dann `systemctl restart kamerplanter.target` aus, oder starte neu.

Ein fehlender Sicherungs-Datenträger hält nichts an: Die Datenbank-Kopie vor einem Update geht an den nächsten Ort.

## Ein älteres Release auf einem neueren Datenträger

Der Datenträger trägt eine Release-Markierung: das höchste Release, dessen Dienste auf ihm die Gesundheitsprüfung bestanden haben. Ein neueres Kamerplanter kann die Daten so migriert haben, dass ein älteres sie nicht lesen kann. Deshalb hält ein älteres Release, und jeder Entwicklungs-Build, die Dienste auf einem Datenträger angehalten, den ein neueres Release markiert hat. Eine Markierung, die sich nicht lesen lässt, lehnt jedes Release ab. Ein Rollback durch die Appliance ist davon nicht betroffen, denn er stellt die Markierung zusammen mit den Daten wieder her. Ein Rollback zu einem Release, das überhaupt keine Datenträger kennt, wird abgelehnt, solange ein Datenträger eingerichtet ist; siehe [Updates und Rollback](updates.md#returning-to-the-previous-release-yourself).

Die Meldung nennt beide Releases, auf der Konsole, in `systemctl status kamerplanter-update-guard.service` und in den letzten Ereignissen von `kamerplanter-update status`. Kehre zum neueren Release zurück oder stelle eine Sicherung von davor wieder her. Um das ältere Release trotzdem auf dem Datenträger zu betreiben, auf das Risiko von Daten hin, die das neuere migriert hat, führe als root aus:

```bash
kamerplanter-update allow-downgrade <disk release> <running release>
```

zum Beispiel `kamerplanter-update allow-downgrade 0.3.0 0.2.0`. Ein Entwicklungs-Build zeigt ein laufendes Release wie `dev`; übernimm beide Werte aus der Meldung. Im Terminal fragt das Kommando nach einer Bestätigung. Es gilt nur für dieses Paar von Releases, wird im Update-Protokoll festgehalten und startet die Dienste.

## Verschlüsselung { #encryption }

Ein Datenträger oder Sicherungs-Datenträger lässt sich beim Formatieren mit LUKS2 verschlüsseln. Gib einen Schlüssel für eine leere Platte mit, oder für eine, die mit `…_FORCE=1` formatiert wird. Eine unverschlüsselt eingerichtete Platte wird nachträglich nie verschlüsselt.

Der Schlüssel kommt von dir oder deinem Provisioner; die Appliance erzeugt nie einen, und in `kamerplanter.env`, die auf dem Datenträger liegt, gibt es keine Einstellung dafür. Gib ihn mit als:

- System-Credential `kamerplanter.data-disk-key` oder `kamerplanter.backup-disk-key`, oder
- Datei dieses Namens in `/var/lib/kamerplanter/disks/keys/`, im Besitz von root mit Modus 0600.

Übergib einen Schlüssel nie auf der Kernel-Kommandozeile (`systemd.set_credential=kamerplanter.data-disk-key:…`): Jeder Benutzer der Appliance kann die Kommandozeile lesen, und das Journal hält sie bei jedem Start fest. Die Appliance lehnt einen solchen Schlüssel ab, speichert ihn nicht und hält die Dienste angehalten, bis er von der Kommandozeile entfernt ist. Betrachte einen Schlüssel, der so übergeben wurde, als anderen bekannt.

Ein Schlüssel hat 32 bis 8192 Bytes und wird Byte für Byte übernommen, einschließlich eines abschließenden Zeilenumbruchs.

Ist die Platte eingerichtet, behält die Appliance den Schlüssel auf der Systemplatte in `/var/lib/kamerplanter/disks/keys/` (root, 0600, Verzeichnis 0700) und öffnet die Platte damit bei jedem Start. Die Kopien dieses Schlüssels, die sie bekommen hat, löscht sie: die Schlüsseldatei, das unverschlüsselte Credential in `/etc/credstore/` oder `/run/credstore/` und das verschlüsselte Credential in `/etc/credstore.encrypted/` oder `/run/credstore.encrypted/`, das sie zum Vergleich entschlüsselt. Eine Kopie, die einen anderen Schlüssel hält oder sich nicht entschlüsseln lässt, bleibt liegen, und das Journal sagt das; lösche sie selbst. Ein Credential aus der Firmware, etwa eine SMBIOS-Zeichenkette, kann sie nicht löschen; siehe [Verbleibende Risiken](#residual-risks). Der Schlüssel erscheint nie in einer Meldung, im Journal oder im Update-Protokoll. Ist die Platte nicht mehr eingerichtet, wird der gespeicherte Schlüssel gelöscht.

Die Appliance verschlüsselt mit `aes-xts-plain64` und einem 512-Bit-Schlüssel und vermerkt beides. Bei jedem Öffnen prüft sie, dass der Container noch so verschlüsselt; ein Container, der das nicht tut, etwa einer, der mit `cipher_null` vorbereitet wurde und die Daten unverschlüsselt ablegt, hält die Dienste angehalten wie eine fremde Platte.

Bewahre eine Kopie des Schlüssels außerhalb der Appliance auf: Ein neues System braucht ihn, um die Platte zu öffnen.

Die Dienste bleiben angehalten, wenn:

- ein Schlüssel für eine unverschlüsselt eingerichtete Platte mitgegeben wird; entferne den Schlüssel
- eine verschlüsselte Platte keinen Schlüssel hat oder keinen, der sie öffnet
- für eine Platte, die formatiert werden soll, zwei verschiedene Schlüssel mitgegeben werden
- ein Sicherungs-Datenträger ohne Schlüssel benannt wird, während der Datenträger verschlüsselt ist

Das Entsperren braucht Zeit: etwa 3 Sekunden auf 2 virtuellen CPUs, länger auf kleiner Hardware.

!!! warning "Wovor Verschlüsselung schützt"
    Ein Schlüssel auf der Systemplatte schützt gegen den Verlust des Datenträgers allein, nicht gegen den Verlust der ganzen Maschine. Mit einem verschlüsselten Datenträger wird ein Sicherungs-Datenträger nur verwendet, wenn er ebenfalls verschlüsselt ist; ein unverschlüsselter wird übergangen, und die Datenbank-Kopie geht an den nächsten Ort.

## Wohin die Datenbank-Kopie vor einem Update geht

Die Kopie geht auf den Sicherungs-Datenträger, sonst auf den Datenträger, sonst auf die Systemplatte. Fehlt ein Ort, ist er zu klein oder nicht verwendbar, nimmt der nächste die Kopie auf, und das Update-Protokoll nennt welchen und warum. Siehe [Updates und Rollback](updates.md#where-the-backup-goes).

## Provisionierung { #provisioning }

Die Platten werden nie über Provisionierungsdaten von cloud-init benannt; für Einstellungen und Secrets aus cloud-init siehe [Provisionierung](../references/provisioning.md).

Ein Provisioner, etwa ein Terraform-Modul, übergibt diese Werte als systemd-Credentials, zum Beispiel als SMBIOS-Typ-11-Zeichenketten einer VM. Benenne die Platten über einen Pfad unter `/dev/disk/by-id/` oder `/dev/disk/by-uuid/`, der im Gast stabil ist:

| Credential | Wert |
|---|---|
| `kamerplanter.data-disk` | Pfad des Datenträgers |
| `kamerplanter.data-disk-force` | `1`, um einen Datenträger mit anderen Signaturen einmalig zu formatieren |
| `kamerplanter.data-disk-key` | Schlüssel des Datenträgers, 32 bis 8192 Bytes; macht eine leere Platte verschlüsselt |
| `kamerplanter.backup-disk` | Pfad des Sicherungs-Datenträgers |
| `kamerplanter.backup-disk-force` | `1`, um einen Sicherungs-Datenträger mit anderen Signaturen einmalig zu formatieren |
| `kamerplanter.backup-disk-key` | Schlüssel des Sicherungs-Datenträgers |

Unter QEMU erscheint ein Datenträger mit der Seriennummer `kpdata` als `/dev/disk/by-id/virtio-kpdata`:

```bash
-drive if=none,id=data,file=data.qcow2,format=qcow2 \
-device virtio-blk-pci,drive=data,serial=kpdata \
-smbios type=11,value=io.systemd.credential:kamerplanter.data-disk=/dev/disk/by-id/virtio-kpdata
```

Ein binärer Schlüssel geht base64-kodiert als `io.systemd.credential.binary:kamerplanter.data-disk-key=…` mit. Übergib einen Schlüssel nur so, als verschlüsseltes Credential oder als Datei; nie auf der Kernel-Kommandozeile.

## Eine Platte außer Dienst stellen { #retiring-a-disk }

Gelöschte Dateien können auf dem Medium lesbar bleiben, auch die Kopie auf der Systemplatte nach einem Umzug. Lösche eine Platte sicher oder zerstöre sie, bevor sie aus der Hand gegeben wird.

- **Sicherungs-Datenträger:** Führe als root aus:

    ```bash
    /usr/libexec/kamerplanter/disks retire backup
    ```

    Das hängt den Sicherungs-Datenträger aus (und schließt ihn, wenn er verschlüsselt ist), während die Dienste weiterlaufen, und löscht dann seine Benennung in `/var/lib/kamerplanter/disks/naming.env`, seinen Eintrag `/var/lib/kamerplanter/disks/backup.env`, seinen gespeicherten Schlüssel und die Einträge des Update-Werkzeugs zu den Sicherungen vor einem Update, die auf ihm liegen. Die nächste Sicherung vor einem Update geht an den nächsten Ort, der sie aufnehmen darf (`kamerplanter-update status` zeigt, welcher). Die Platte selbst bleibt, wie sie ist; zieh sie ab oder lösche sie sicher, bevor sie aus der Hand gegeben wird. Sicherungen auf dieser Platte lassen sich nicht mehr wiederherstellen.

    Der Befehl ändert nichts und sagt, warum, wenn:

    - ein Credential `kamerplanter.backup-disk` oder die Einstellung `BACKUP_DISK` in deiner Datei die Platte noch benennt: Entferne diese Benennung zuerst, sonst richtet der nächste Start die Platte wieder ein;
    - ein Update noch nicht entschieden ist (`kamerplanter-update status`), da seine Rückkehr die Sicherung von davor wiederherstellen würde, oder eine andere Update-Aktion, die Sicherung vor einem Update oder ihre Gesundheitsprüfung läuft: Versuche es wieder, wenn sie fertig ist;
    - die Platte sich nicht aushängen lässt, weil etwas sie verwendet.

    Ist die Platte ausgehängt, lässt sich ihr verschlüsselter Container aber nicht schließen, sagt der Befehl das und bricht ab; bis du ihn erneut ausführst oder neu startest, behandelt das Update-Werkzeug den Sicherungs-Datenträger als fehlend.

- **Datenträger:** Dieses Release kann die Daten weder auf die Systemplatte zurück noch auf einen anderen Datenträger umziehen; solange ein Datenträger eingerichtet ist, wird eine andere Benennung übergangen. Lösche `/var/lib/kamerplanter/disks/data.env` nicht, solange deine Daten auf der Platte liegen: Ohne diese Datei verwendet die Appliance die Platte nicht mehr.

## Verbleibende Risiken { #residual-risks }

Die Appliance schließt, was sie kann, aber einige Risiken bleiben mit dem Entwurf oder mit der Hardware. Kenne sie, bevor du eine Platte und einen Schlüssel wählst.

**Eine unverschlüsselte Platte lässt sich gegen eine gefälschte tauschen.** Ein unverschlüsselter Datenträger oder Sicherungs-Datenträger wird nur an seinem Label und an der UUID seines Dateisystems erkannt. Beides sind einfache Werte, die jeder auf einen anderen Stick übertragen kann. Wer die Platte tauschen kann, während die Appliance aus ist, kann sie dazu bringen, seine eigene anzunehmen: Ein gefälschter Datenträger bringt dessen Secrets und Datenbank mit, und ein gefälschter Sicherungs-Datenträger erhält mit dem nächsten Update eine vollständige Kopie deiner Datenbank. Beim Prüfen und Einhängen einer solchen Platte liest der Kernel außerdem als root ein Dateisystem, das jemand anderes vorbereitet hat. Nur Verschlüsselung bindet eine Platte an dich, denn ein LUKS2-Container öffnet sich nur mit deinem Schlüssel. **Was zu tun ist:** [Verschlüssele](#encryption) jede Platte, die sich abziehen lässt oder das Gelände verlassen kann, und stelle die Maschine so auf, dass andere nicht an ihre Anschlüsse kommen.

**Ein Schlüssel aus der Firmware bleibt lesbar.** Ein Schlüssel, der als SMBIOS-Typ-11-Credential übergeben wird, bleibt für root lesbar, solange die Appliance läuft, in den Firmware-Tabellen unter `/sys/firmware/dmi/` und in den System-Credentials unter `/run/credentials/`. Er liegt außerdem im Klartext in der VM-Konfiguration des Hypervisors und in den Dateien des Provisioners, etwa einer Terraform-Konfiguration und ihrem State. Keine dieser Kopien kann die Appliance löschen. **Was zu tun ist:** Beschränke, wer die VM-Konfiguration und den State des Provisioners lesen kann, und entferne das Credential aus der VM, sobald die Platte eingerichtet ist; die Appliance behält ihre eigene Kopie auf der Systemplatte.

**Gelöschte Schlüssel und Kopien können auf Flash-Speicher bleiben.** Die Appliance überschreibt den gespeicherten Schlüssel, die mitgegebenen Kopien davon sowie die Secrets und Aufzeichnungen der Kopie umgezogener Daten auf der Systemplatte, bevor sie sie löscht; den Rest dieser Kopie, die Datenbanken, löscht sie nur. Auf einer SSD, einem USB-Stick oder einem Copy-on-Write-Dateisystem können die alten Blöcke trotzdem lesbar bleiben, weil das Medium an anderer Stelle schreibt und die alten Blöcke erst später freigibt. **Was zu tun ist:** Folge [Eine Platte außer Dienst stellen](#retiring-a-disk); lösche ein Medium sicher oder zerstöre es, bevor es aus der Hand gegeben wird, die Systemplatte eingeschlossen.

**Eine alte Kopie der verschlüsselten Platte wird angenommen.** LUKS2, wie die Appliance es einrichtet, verschlüsselt, erkennt aber nicht, wenn der Inhalt als Ganzes ersetzt wird. Wer mit Zugang zur Hardware die verschlüsselte Platte früher kopiert hat, kann diese Kopie zurückschreiben. Sie öffnet sich mit dem gespeicherten Schlüssel, unter derselben UUID, und die Appliance verwendet die ältere Datenbank, die älteren Secrets und die ältere Release-Markierung darauf. **Was zu tun ist:** Halte die Maschine und ihre Platten unter Verschluss, und prüfe die Daten, nachdem die Appliance aus deinen Händen war.

**Der Schlüssel liegt auf der Systemplatte.** Die Appliance hält den Schlüssel einer verschlüsselten Platte im Klartext auf der Systemplatte und bindet ihn nicht an das TPM; wer die ganze Maschine hat, oder die Systemplatte und den Datenträger, kann den Datenträger öffnen. Siehe [Wovor Verschlüsselung schützt](#encryption). **Was zu tun ist:** Betrachte die Systemplatte als Trägerin des Schlüssels; bewahre deine eigene Kopie des Schlüssels außerhalb der Appliance auf, und schütze die Maschine als Ganzes.
