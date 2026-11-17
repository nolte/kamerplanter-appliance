---
title: Konfiguration
audience: [self-hoster]
content_mode: reference
track: user-docs
last_updated: 2026-11-16
---

# Konfiguration

Die Kamerplanter-Einstellungen stammen aus vier Schichten. Ein Wert in einer späteren Schicht gewinnt gegenüber demselben Schlüssel in einer früheren.

| Schicht | Datei | Wer schreibt sie |
|---|---|---|
| Standardwerte | `/usr/share/kamerplanter/kamerplanter.env` | Das Image; jedes Update ersetzt sie |
| [Provisionierung](provisioning.md) | `/var/lib/kamerplanter/provisioning/provisioning.env`, danach `/var/lib/kamerplanter/provisioning/settings.env` | cloud-init, aus den Provisionierungsdaten; ohne sie leer |
| Secrets | `/etc/kamerplanter/secrets.env` | Die Appliance, einmal je Schlüssel: erzeugt oder provisioniert |
| Deine eigenen Werte | `/etc/kamerplanter/kamerplanter.env` | Du; bleibt über Updates und Rollbacks erhalten |

Mit einem [Datenträger](../getting-started/data-disk.md) liegen `/etc/kamerplanter/` und `/var/lib/kamerplanter/pinned/` auf diesem; die Pfade bleiben dieselben. Die Provisionierungsschicht bleibt auf der Systemplatte.

Jede Zeile ist `KEY=VALUE` und wird wörtlich übernommen: Anführungszeichen werden nicht entfernt, führende Leerzeichen und Zeilen mit `#` am Anfang werden übersprungen. Bei jedem Boot führt die Appliance die Schichten zusammen, prüft sie und schreibt das Ergebnis nach `/run/kamerplanter/`; die Dienste lesen nur dieses Ergebnis. Eine Änderung übernimmst du mit:

```bash
systemctl restart kamerplanter.target
```

## Die Appliance über ihre Adresse erreichen

Die Standardwerte erwarten die Web-UI unter `http://localhost:8080`. Rufst du sie über die Adresse der Appliance oder einen Hostnamen auf, trage diese Herkunft in deine Datei ein, zum Beispiel:

```ini
CORS_ORIGINS=["http://kamerplanter.local:8080"]
FRONTEND_URL=http://kamerplanter.local:8080
```

## Erzeugte Secrets

Bei jedem Boot erzeugt die Appliance jedes verlangte Secret, das noch fehlt: `ARANGODB_PASSWORD`, `JWT_SECRET_KEY`, `FERNET_KEY`, `ERASURE_TOMBSTONE_SALT` und `LOG_PSEUDONYM_SALT`. Ein Secret, das ein späteres Release neu verlangt, entsteht beim ersten Boot dieses Releases. Ausgenommen sind die drei Werte unter [Werte, die sich nicht ändern dürfen](#werte-die-sich-nicht-andern-durfen): Ist ein Dienst einmal mit einem davon gestartet, wird er nicht neu erzeugt, sondern muss aus einem Backup kommen. Ein neuer `JWT_SECRET_KEY` beendet nur alle Sitzungen, ein neuer `LOG_PSEUDONYM_SALT` trennt nur die Zuordnung zu älteren Logzeilen.

Willst du stattdessen einen eigenen Wert, trage ihn in `/etc/kamerplanter/kamerplanter.env` ein, am besten vor dem ersten Start. Um ihn schon vor dem ersten Boot mitzugeben, nutze die Provisionierungsdaten (`kamerplanter:` → `secrets:`) oder das System-Credential `kamerplanter.secret.<KEY>`; siehe [Provisionierung](provisioning.md#secrets).

## Updates

`UPDATE_WINDOW`, `UPDATE_HEALTH_TIMEOUT` und `UPDATE_BACKUP_KEEP_DAYS` legen fest, wann Updates aktiviert und wie sie geprüft werden; siehe [Updates und Rollback](../getting-started/updates.md#einstellungen). Die Konfigurationsprüfung lehnt ein Fenster ab, das nicht `HH:MM` ist, und eine Frist oder Aufbewahrungsdauer, die keine ganze Zahl ist, eine Frist über 9999 Minuten oder eine Aufbewahrungsdauer mit mehr als sechs Stellen.

## Datenträger und Sicherungs-Datenträger

| Einstellung | Standard | Bedeutung |
|---|---|---|
| `DATA_DISK` | leer | Der Datenträger, als Pfad unter `/dev/disk/by-id/` oder `/dev/disk/by-uuid/`; leer: keiner |
| `DATA_DISK_FORCE` | `0` | `1` formatiert einen benannten Datenträger, der ein anderes Dateisystem oder eine Partitionstabelle trägt, einmal je Gerät |
| `BACKUP_DISK` | leer | Der Sicherungs-Datenträger, ebenso benannt |
| `BACKUP_DISK_FORCE` | `0` | `1` formatiert einen benannten Sicherungs-Datenträger, der ein anderes Dateisystem oder eine Partitionstabelle trägt, einmal je Gerät |

Diese vier Einstellungen gelten in deiner eigenen Datei nur, solange kein Datenträger eingerichtet ist. Ist einer eingerichtet, liegt diese Datei auf dem Datenträger; die Appliance ignoriert sie dann dort und sagt das in `systemctl status kamerplanter-data-disk`. In der [Provisionierungsschicht](provisioning.md#lifecycle-of-the-settings) werden sie immer ignoriert. Setze sie stattdessen als root auf der Systemplatte:

```bash
/usr/libexec/kamerplanter/disks name backup /dev/disk/by-id/ata-Example_SSD_ABC123
```

Das Kommando schreibt `/var/lib/kamerplanter/disks/naming.env`; hänge `force` an den Pfad an, um die Platte einmalig zu formatieren, obwohl sie andere Signaturen trägt, oder gib `none` statt eines Pfads an, um die Benennung zu entfernen.

Ein Provisioner übergibt dasselbe als System-Credentials `kamerplanter.data-disk`, `kamerplanter.data-disk-force`, `kamerplanter.backup-disk` und `kamerplanter.backup-disk-force`. Der Schlüssel einer verschlüsselten Platte ist hier nie eine Einstellung, da diese Datei auf dem Datenträger liegt: Er kommt als Credential `kamerplanter.data-disk-key` oder `kamerplanter.backup-disk-key` oder als Datei dieses Namens in `/var/lib/kamerplanter/disks/keys/`. Die Konfigurationsprüfung lehnt eine Platte ab, die über eine andere Art von Pfad benannt ist. Siehe [Datenträger und Sicherungs-Datenträger](../getting-started/data-disk.md).

## Prüfungen vor dem Start der Dienste

Die Dienste bleiben gestoppt, mit einer Meldung in `systemctl status kamerplanter-config`, wenn:

- `FERNET_KEY` kein gültiger Fernet-Schlüssel ist (44 Zeichen, URL-sicheres Base64)
- `ERASURE_TOMBSTONE_SALT`, `LOG_PSEUDONYM_SALT` oder ein gesetztes `TENANT_EXPORT_SIGNING_SECRET` kürzer als 32 Zeichen ist
- `JWT_SECRET_KEY` oder das Datenbankpasswort leer oder ein bekannter Standardwert ist
- ein [provisionierter](provisioning.md) `JWT_SECRET_KEY` kürzer als 32 Zeichen oder ein provisioniertes Datenbankpasswort kürzer als 16 Zeichen ist, bevor die Dienste zum ersten Mal gestartet sind; steht ein so kurzer Wert in deiner Datei oder in `secrets.env` oder wird er einer schon gestarteten Installation provisioniert, gibt es nur eine Warnung, die den Schlüssel nennt, damit eine bestehende Installation weiter startet; ersetze ihn durch einen längeren (das Datenbankpasswort änderst du zuerst in der Datenbank und entfernst dann seinen Pin, wie die Warnung sagt)
- `ARANGODB_USERNAME` einen anderen Wert als `root` hat: Das Datenbank-Image legt nur seinen Root-Nutzer an, und `ARANGO_ROOT_PASSWORD` wird immer aus `ARANGODB_PASSWORD` übernommen
- eine Zeile in einer der Dateien nicht `KEY=VALUE` ist
- sich einer der Werte unten geändert hat oder fehlt, nachdem ein Dienst damit gestartet ist

## Werte, die sich nicht ändern dürfen

| Wert | Warum |
|---|---|
| `ERASURE_TOMBSTONE_SALT` | Schlüsselt die Nachweise gelöschter Konten; darf sich nie ändern |
| `FERNET_KEY` | Gespeicherte Zugangsdaten sind damit verschlüsselt und würden unlesbar |
| `ARANGODB_PASSWORD` | Die Datenbank behält das Passwort, mit dem sie angelegt wurde |

Unmittelbar bevor ein Dienst zum ersten Mal mit einem davon startet, wird ein Hash unter `/var/lib/kamerplanter/pinned/` festgehalten: das Datenbankpasswort vor dem Start von ArangoDB, die anderen beiden vor dem Start der API. Fehlt ein solcher Wert danach in `secrets.env`, wird er nicht neu erzeugt; stelle ihn aus deinem Backup wieder her. Um einen bewusst zu ändern, erledige zuerst, was sein Grund verlangt, beim Datenbankpasswort: in der Datenbank ändern, dann `ARANGODB_PASSWORD` in deiner Datei setzen, dann `/var/lib/kamerplanter/pinned/ARANGODB_PASSWORD` löschen und neu starten.

!!! warning "Backups"
    Sichere `/etc/kamerplanter/secrets.env` zusammen mit deinen Daten. Ohne den passenden `FERNET_KEY` und `ERASURE_TOMBSTONE_SALT` verlieren wiederhergestellte Daten ihre verschlüsselten Felder und Löschnachweise. Mit einem Datenträger liegen beide auf diesem; der Datenträger selbst ist keine Sicherung, und die Datenbank-Kopie vor einem Update auf einem Sicherungs-Datenträger enthält nur die Datenbanken, nicht die Secrets. Der Schlüssel einer verschlüsselten Platte liegt auf der Systemplatte; bewahre auch von ihm eine Kopie auf.
