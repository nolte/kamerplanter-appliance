---
title: Konfiguration
audience: [self-hoster]
content_mode: reference
track: user-docs
last_updated: 2026-11-13
---

# Konfiguration

Die Kamerplanter-Einstellungen stammen aus drei Dateien. Ein Wert in einer späteren Datei gewinnt gegenüber demselben Schlüssel in einer früheren.

| Datei | Inhalt | Wer schreibt sie |
|---|---|---|
| `/usr/share/kamerplanter/kamerplanter.env` | Standardwerte | Das Image; jedes Update ersetzt sie |
| `/etc/kamerplanter/secrets.env` | Erzeugte Secrets | Die Appliance, einmal je Schlüssel |
| `/etc/kamerplanter/kamerplanter.env` | Deine eigenen Werte | Du; bleibt über Updates und Rollbacks erhalten |

Jede Zeile ist `KEY=VALUE` und wird wörtlich übernommen: Anführungszeichen werden nicht entfernt, führende Leerzeichen und Zeilen mit `#` am Anfang werden übersprungen. Bei jedem Boot führt die Appliance die drei Dateien zusammen, prüft sie und schreibt das Ergebnis nach `/run/kamerplanter/`; die Dienste lesen nur dieses Ergebnis. Eine Änderung übernimmst du mit:

```bash
systemctl restart kamerplanter.target
```

## Erzeugte Secrets

Bei jedem Boot erzeugt die Appliance jedes verlangte Secret, das noch fehlt, außer einem der Werte unten, mit dem ein Dienst bereits gestartet ist: `ARANGO_ROOT_PASSWORD` und `ARANGODB_PASSWORD` (ein gemeinsamer Wert), `JWT_SECRET_KEY`, `FERNET_KEY`, `ERASURE_TOMBSTONE_SALT` und `LOG_PSEUDONYM_SALT`. Ein Secret, das ein späteres Release neu verlangt, entsteht beim ersten Boot dieses Releases.

Willst du stattdessen einen eigenen Wert, trage ihn in `/etc/kamerplanter/kamerplanter.env` ein, am besten vor dem ersten Start.

## Prüfungen vor dem Start der Dienste

Die Dienste bleiben gestoppt, mit einer Meldung in `systemctl status kamerplanter-config`, wenn:

- `FERNET_KEY` kein gültiger Fernet-Schlüssel ist (44 Zeichen, URL-sicheres Base64)
- `ERASURE_TOMBSTONE_SALT`, `LOG_PSEUDONYM_SALT` oder ein gesetztes `TENANT_EXPORT_SIGNING_SECRET` kürzer als 32 Zeichen ist
- `JWT_SECRET_KEY` oder das Datenbankpasswort leer oder ein bekannter Standardwert ist
- `ARANGO_ROOT_PASSWORD` und `ARANGODB_PASSWORD` sich unterscheiden, während der Datenbanknutzer `root` ist
- sich einer der Werte unten geändert hat oder fehlt, nachdem ein Dienst damit gestartet ist

## Werte, die sich nicht ändern dürfen

| Wert | Warum |
|---|---|
| `ERASURE_TOMBSTONE_SALT` | Schlüsselt die Nachweise gelöschter Konten; darf sich nie ändern |
| `FERNET_KEY` | Gespeicherte Zugangsdaten sind damit verschlüsselt und würden unlesbar |
| `ARANGODB_PASSWORD` | Die Datenbank behält das Passwort, mit dem sie angelegt wurde |

Sobald ein Dienst mit einem davon gestartet ist, wird ein Hash unter `/var/lib/kamerplanter/pinned/` festgehalten: das Datenbankpasswort, wenn ArangoDB läuft, die anderen beiden, wenn die API läuft. Fehlt ein solcher Wert danach in `secrets.env`, wird er nicht neu erzeugt; stelle ihn aus deinem Backup wieder her. Um einen bewusst zu ändern, erledige zuerst, was sein Grund verlangt, beim Datenbankpasswort: in der Datenbank ändern, dann beide Passwort-Schlüssel in deiner Datei setzen, dann `/var/lib/kamerplanter/pinned/ARANGODB_PASSWORD` löschen und neu starten.

!!! warning "Backups"
    Sichere `/etc/kamerplanter/secrets.env` zusammen mit deinen Daten. Ohne den passenden `FERNET_KEY` und `ERASURE_TOMBSTONE_SALT` verlieren wiederhergestellte Daten ihre verschlüsselten Felder und Löschnachweise.
