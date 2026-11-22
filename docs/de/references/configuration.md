---
title: Konfiguration
audience: [self-hoster]
content_mode: reference
track: user-docs
last_updated: 2026-11-21
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

`CORS_ORIGINS` nennt die Herkünfte, von denen aus die Web-UI die API aufrufen darf, `FRONTEND_URL` die Adresse der Web-UI in Links, etwa in E-Mails. Setzt keine Schicht sie, leitet die Appliance sie bei jedem Boot und bei jedem `systemctl restart kamerplanter.target` aus ihrem statischen Hostnamen (`/etc/hostname`, wie die Provisionierung oder du ihn gesetzt hast) und ihren Adressen in diesem Moment ab, sobald das Netzwerk steht:

| Einstellung | Abgeleiteter Wert |
|---|---|
| `FRONTEND_URL` | `http://<Hostname>:8080`, wenn der Hostname einen Punkt enthält, etwa `kamerplanter.example.org`; sonst `http://<erste IPv4-Adresse>:8080`; ohne IPv4-Adresse `http://<Hostname>:8080`; ohne beides `http://localhost:8080` |
| `CORS_ORIGINS` | die Herkunft des geltenden `FRONTEND_URL`, auch eines selbst gesetzten, `http://<Hostname>:8080`, `http://<Hostname>.local:8080` für einen Hostnamen ohne Punkt, `http://<Adresse>:8080` für jede globale IPv4- und IPv6-Adresse und `http://localhost:8080` |

Ein Hostname `localhost` oder `localhost.localdomain` oder einer, der kein gültiger DNS-Name ist, zählt als keiner. Den flüchtigen Hostnamen, den NetworkManager ohne statischen Hostnamen per DHCP bezieht, nutzt die Appliance nie; so kann ein DHCP-Server die Adresse in den Links nicht bestimmen. Außen vor bleiben die Adressen der Container-Netzwerke sowie temporäre, veraltete oder vorläufige IPv6-Adressen und solche, deren Duplikatprüfung fehlgeschlagen ist. `journalctl -b -u kamerplanter-config` nennt die abgeleiteten Werte und warnt, wenn ein selbst gesetzter `FRONTEND_URL` keine Herkunft ergibt. Ein abgeleiteter Wert folgt dem Gerät: Ein neuer Hostname oder eine neue Adresse gilt ab dem nächsten Boot oder `systemctl restart kamerplanter.target`. Eine Adresse, die erst nach dem Netzwerkstart dazukommt, etwa eine IPv6-Adresse, deren Prüfung noch läuft, oder eine neue DHCP-Lease, ist bis dahin keine Herkunft; erreichst du die Web-UI über eine solche Adresse, setze `CORS_ORIGINS` selbst.

Um einen Wert festzulegen, etwa einen Namen hinter einem Reverse Proxy, trage ihn in deine Datei ein; einen Wert, den irgendeine Schicht setzt, auch einen leeren, übernimmt die Appliance unverändert und leitet für diesen Schlüssel nichts ab:

```ini
CORS_ORIGINS=["https://kamerplanter.example.org"]
FRONTEND_URL=https://kamerplanter.example.org
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

Unmittelbar bevor ein Dienst zum ersten Mal mit einem davon startet, wird ein mit einem Schlüssel gebildeter Hash (HMAC-SHA256) unter `/var/lib/kamerplanter/pinned/` festgehalten: das Datenbankpasswort vor dem Start von ArangoDB, die anderen beiden vor dem Start der API. Der Schlüssel wird einmal je Gerät erzeugt und liegt neben den Aufzeichnungen, in `/var/lib/kamerplanter/pinned/.key`; lösche ihn nie und kopiere ihn mit, wenn du das Verzeichnis kopierst (ein Glob `pinned/*` übergeht ihn), denn ohne ihn lässt sich keine Aufzeichnung prüfen und die Dienste bleiben gestoppt. Fehlt ein solcher Wert danach in `secrets.env`, wird er nicht neu erzeugt; stelle ihn aus deinem Backup wieder her. Um einen bewusst zu ändern, erledige zuerst, was sein Grund verlangt, beim Datenbankpasswort: in der Datenbank ändern, dann `ARANGODB_PASSWORD` in deiner Datei setzen, dann `/var/lib/kamerplanter/pinned/ARANGODB_PASSWORD.hmac` löschen und neu starten. Frühere Releases haben einen Hash ohne Schlüssel in `/var/lib/kamerplanter/pinned/ARANGODB_PASSWORD` usw. festgehalten; auf einer aktualisierten Appliance wird eine solche Aufzeichnung wie bisher geprüft und die mit Schlüssel daneben geschrieben, ohne die Dienste zu stoppen. Die Aufzeichnung ohne Schlüssel wird beim ersten Start gelöscht, nachdem das Update seine Gesundheitsprüfung bestanden hat, damit das Release, zu dem ein automatischer Rollback zurückkehrt, sie noch vorfindet. Die Meldung zu einem geänderten Wert nennt die Dateien, die zu löschen sind. Liegt eine Aufzeichnung ohne Schlüssel vor, entscheidet sie: Ein Wert, der nach einem Rollback auf einem früheren Release geändert wurde (wie dessen Dokumentation es beschreibt), wird beim Zurückkehren angenommen und die Aufzeichnung mit Schlüssel neu geschrieben. Sind die Aufzeichnungen ohne Schlüssel gelöscht, verhindert eine manuelle Rückkehr zu einem früheren Release (`kamerplanter-update rollback`) nicht mehr, dass ein fehlender Wert neu erzeugt wird, da jenes Release nur die Aufzeichnungen ohne Schlüssel prüft: Stelle vor einer solchen Rückkehr sicher, dass `secrets.env` jeden Wert enthält. Der Schlüssel schützt Kopien der Aufzeichnungen ohne ihn; wer das ganze Verzeichnis lesen kann, etwa auf einem abgezogenen, unverschlüsselten Datenträger, hat auch den Schlüssel und kann kurze Werte weiterhin gegen die Aufzeichnungen durchprobieren.

!!! warning "Backups"
    Sichere `/etc/kamerplanter/secrets.env` zusammen mit deinen Daten. Ohne den passenden `FERNET_KEY` und `ERASURE_TOMBSTONE_SALT` verlieren wiederhergestellte Daten ihre verschlüsselten Felder und Löschnachweise. Mit einem Datenträger liegen beide auf diesem; der Datenträger selbst ist keine Sicherung, und die Datenbank-Kopie vor einem Update auf einem Sicherungs-Datenträger enthält nur die Datenbanken, nicht die Secrets. Der Schlüssel einer verschlüsselten Platte liegt auf der Systemplatte; bewahre auch von ihm eine Kopie auf.
