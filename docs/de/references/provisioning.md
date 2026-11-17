---
title: Provisionierung
audience: [self-hoster]
content_mode: reference
track: user-docs
last_updated: 2026-11-16
---

# Provisionierung

Provisionierungsdaten richten eine Appliance beim Boot ein, ohne dass du dich anmeldest: Hostname, Netzwerk, einen SSH-Schlüssel für root sowie deine eigenen Kamerplanter-Einstellungen und Secrets. Die Appliance liest sie mit cloud-init. Eine Automatisierung wie ein Terraform-Modul nutzt dieselbe Schnittstelle.

Ohne Provisionierungsdaten bleibt cloud-init abgeschaltet, und die Appliance verhält sich wie bisher: Sie bezieht ihre Adresse über DHCP und schließt ihre Einrichtung beim ersten Boot ab.

## Quellen { #sources }

| Quelle | Wie |
|---|---|
| NoCloud-Laufwerk | Ein Laufwerk mit dem Label `CIDATA`, formatiert als vfat oder ISO 9660: ein virtuelles Laufwerk der VM oder ein USB-Stick an deiner eigenen Hardware |
| Seed-URL | `ds=nocloud;s=<URL>` auf der Kernel-Kommandozeile oder als SMBIOS-Seriennummer des Systems; die URL liefert `meta-data` und `user-data` |
| Seed-Dateien | Dieselben Dateien unter `/var/lib/cloud/seed/nocloud/` auf der Systemplatte, zusammen mit einer eigenen Datei in `/etc/cloud/cloud.cfg.d/`; siehe unten |
| Hetzner Cloud | Der Metadatendienst des Anbieters; gib die User-Data beim Anlegen des Servers an |
| OVHcloud | Der OpenStack-Metadatendienst oder das ConfigDrive, das OpenStack und OVHclouds „Bring Your Own Image“ anhängen |

!!! note
    Die Appliance liest die Quellen von Hetzner Cloud und OVHcloud, sie sind aber noch nicht auf einem echten Server getestet.

Ein NoCloud-Laufwerk und die Seed-Dateien enthalten diese Dateien:

| Datei | Inhalt |
|---|---|
| `meta-data` | `instance-id:` und `local-hostname:` |
| `user-data` | Die Cloud-Config, beginnend mit der Zeile `#cloud-config` |
| `network-config` | Optional, eine statische Netzwerkkonfiguration |

Ein vfat-Laufwerk, als Image-Datei für eine VM oder auf einen USB-Stick geschrieben:

```bash
truncate -s 4M cidata.img
mkfs.vfat -n CIDATA cidata.img
mcopy -i cidata.img meta-data user-data network-config ::/
```

Eine Seed-URL als Seriennummer einer QEMU-VM, die URL endet auf `/`:

```bash
-smbios 'type=1,serial=ds=nocloud;s=http://10.0.2.2:8099/'
```

Wer unter einer Seed-URL antwortet, bestimmt bei jedem Boot, was die Appliance als root ausführt. Liefere sie über `https://` von einem Host, den du kontrollierst, oder über einfaches HTTP nur in einem Netz, dem du vertraust, und entferne die URL, sobald die Appliance gestartet ist.

### Seed-Dateien { #seed-files }

Seed-Dateien brauchen eine eigene Konfigurationsdatei in `/etc/cloud/cloud.cfg.d/`, zum Beispiel `90-nocloud-seed.cfg`, mit genau dieser Zeile:

```yaml
datasource_list: [ NoCloud, None ]
```

cloud-init wählt seine Quelle, bevor `/var` eingehängt ist. Solange es unter mehreren Quellen wählt, findet es die Seed-Dateien nicht; mit NoCloud als einziger Quelle liest es sie später. Das Image liefert diese Datei nicht mit, weil cloud-init sonst bei jedem Boot liefe und die Metadatendienste nicht mehr läse. Gib der Datei einen Namen, der nach `50-kamerplanter.cfg` des Images sortiert, und lass den Schlüssel auf einer Zeile.

## Was cloud-init übernimmt { #what-cloud-init-applies }

- den Hostnamen
- die Netzwerkkonfiguration, etwa eine statische IPv4-Adresse, Gateway und DNS-Server
- die SSH-Schlüssel aus `ssh_authorized_keys`, für root

Es wird kein Standardnutzer angelegt, auch nicht mit `users: [ default ]`. SSH nimmt nie ein Passwort an, auch wenn die User-Data `ssh_pwauth: true` setzt. cloud-init vergrößert keine Partitionen und Dateisysteme.

### Statisches Netzwerk { #static-network }

Zwei Formen von network-config Version 2 werden unterstützt: jeder `ethernets`-Eintrag mit dem Namen der Schnittstelle auf der Appliance als Schlüssel, oder zugeordnet über `match: macaddress:` zusammen mit `set-name:`. Ein `match:` ohne `set-name:` wird nicht unterstützt; die Verbindung kommt nie hoch, und die Appliance bleibt bei DHCP.

```yaml
version: 2
ethernets:
  lan0:
    match:
      macaddress: "52:54:00:12:34:56"
    set-name: lan0
    dhcp4: false
    addresses: [192.168.1.50/24]
    routes:
      - to: default
        via: 192.168.1.1
    nameservers:
      addresses: [192.168.1.1]
```

Ob die Netzwerkkonfiguration funktioniert, die Proxmox VE für sein Cloud-Init-Laufwerk erzeugt, ist noch nicht getestet. Gib im Zweifel eine eigene network-config in einer der beiden Formen oben an.

## Kamerplanter-Einstellungen und Secrets { #kamerplanter-settings-and-secrets }

Trage deine Einstellungen unter `kamerplanter:` → `settings:` ein und deine Secrets unter `kamerplanter:` → `secrets:`:

```yaml
#cloud-config
hostname: kamerplanter
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample you@example
kamerplanter:
  settings:
    FRONTEND_URL: "http://kamerplanter.local:8080"
    CORS_ORIGINS: '["http://kamerplanter.local:8080"]'
    UPDATE_WINDOW: "04:15"
  secrets:
    JWT_SECRET_KEY: "4f0c7d9e2b1a8c6e5d3f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d"
write_files:
  - path: /var/lib/kamerplanter/provisioning/provisioning.env
    permissions: '0600'
    content: |
      REGISTRATION_MODE=invite_only
```

Jeder Eintrag unter `settings:` wird zu einer Zeile `KEY=VALUE`. Eine Zahl oder `true`/`false` wird als ihr Text geschrieben, ein leerer Wert als `KEY=`. Setze jeden Wert in Anführungszeichen: `UPDATE_WINDOW: 22:30` ohne Anführungszeichen ist in YAML die Zahl 1350, und ein Wert in eckigen Klammern ist eine Liste. Eine Liste, eine Map oder ein Wert über mehrere Zeilen hält die Dienste gestoppt. Jeder Wert unter `secrets:` muss Text in Anführungszeichen sein.

Statt der Map oder zusätzlich kann `write_files` die Datei `/var/lib/kamerplanter/provisioning/provisioning.env` im Format [deiner eigenen Datei](configuration.md) schreiben. Für einen Schlüssel, den beide setzen, gewinnt die Map. Keine von beiden schreibt je `/etc/kamerplanter/kamerplanter.env`.

`write_files` läuft einmal je Instanz, beim ersten Boot mit einer neuen `instance-id`. Ein Eintrag mit `defer: true` gilt erst ab dem nächsten Boot.

## Lebenszyklus der Einstellungen { #lifecycle-of-the-settings }

Die Einstellungen bilden die Provisionierungsschicht, zwischen den Standardwerten des Images und `secrets.env`; deine eigene Datei gewinnt gegenüber ihnen. Siehe [Konfiguration](configuration.md).

| Datei | Geschrieben |
|---|---|
| `/var/lib/kamerplanter/provisioning/provisioning.env` | Von `write_files`, einmal je Instanz; du darfst sie an Ort und Stelle bearbeiten |
| `/var/lib/kamerplanter/provisioning/settings.env` | Aus `kamerplanter:` → `settings:`, bei jedem Boot mit Provisionierungsdaten; deine Änderungen gehen verloren |

Beide liegen auf der Systemplatte, auch mit einem [Datenträger](../getting-started/data-disk.md), und sind nur für root lesbar. Bei jedem Boot mit Provisionierungsdaten wird `settings.env` aus der Map erneuert, auch aus einer leeren, sodass ein geänderter Wert nach dem nächsten Boot gilt. Bei einem Boot ohne Provisionierungsdaten bleibt sie, wie sie ist: Die Einstellungen bleiben in Kraft, nachdem du die Quelle entfernt hast. Sie gelten ab dem ersten Start der Dienste; ein provisioniertes `UPDATE_WINDOW` setzt das Wartungsfenster ab dem ersten Boot.

Ein provisionierter Wert wird wie ein Wert deiner Datei geprüft. Ein ungültiger hält die Dienste gestoppt, und die Meldung nennt die Provisionierungsschicht:

```bash
systemctl status kamerplanter-config
```

```text
Kamerplanter configuration is invalid; the services stay stopped:
  - UPDATE_WINDOW is not a time of day as HH:MM (the window starts at 03:00 until it is fixed) (set in the provisioning layer (kamerplanter: -> settings: of the provisioning data, in /var/lib/kamerplanter/provisioning/settings.env))
```

Korrigiere ihn in den Provisionierungsdaten und starte neu, oder setze ihn in `/etc/kamerplanter/kamerplanter.env`, das gewinnt, und führe `systemctl restart kamerplanter.target` aus.

Zwei Arten von Schlüsseln behandelt die Provisionierungsschicht anders:

- `DATA_DISK`, `BACKUP_DISK`, `DATA_DISK_FORCE` und `BACKUP_DISK_FORCE` werden mit einer Meldung ignoriert. Benenne eine Platte mit `disks name` oder als System-Credential; siehe [Datenträger und Sicherungs-Datenträger](../getting-started/data-disk.md#setting-up-a-disk).
- Ein erzeugtes Secret wie `FERNET_KEY` unter `settings:` wird mit einer Warnung durchgereicht, die den Schlüssel nennt. Es bleibt im Klartext in der Provisionierungsschicht; trage es stattdessen unter `secrets:` ein.

## Secrets { #secrets }

Die Appliance übernimmt `kamerplanter:` → `secrets:` einmal je Instanz nach `/etc/kamerplanter/secrets.env`, beim ersten Boot, bei dem sie diese Datei schreiben kann. Sie füllt nur Schlüssel, die die Datei noch nicht enthält. Enthält die Datei einen anderen Wert, auch auf einem übernommenen Datenträger, bleibt dieser Wert; eine Warnung nennt den Schlüssel, nie den Wert, und die Dienste starten wie gewohnt. Ein Secret erscheint nie in der Provisionierungsschicht, im Journal, auf der Konsole oder in der Ausgabe eines Kommandos. Einmal übernommen, bleibt es erhalten wie ein [erzeugtes Secret](configuration.md#erzeugte-secrets); sichere es genauso.

Die Appliance übernimmt nur diese Schlüssel:

| Schlüssel | Regel über 1 bis 4096 druckbare ASCII-Zeichen auf einer Zeile hinaus |
|---|---|
| `ARANGODB_PASSWORD` | Mindestens 16 Zeichen, kein bekannter Standardwert |
| `JWT_SECRET_KEY` | Mindestens 32 Zeichen, nicht der Platzhalter von Upstream |
| `FERNET_KEY` | Ein Fernet-Schlüssel: 44 Zeichen, URL-sicheres Base64 |
| `ERASURE_TOMBSTONE_SALT` | Mindestens 32 Zeichen |
| `LOG_PSEUDONYM_SALT` | Mindestens 32 Zeichen |
| `TENANT_EXPORT_SIGNING_SECRET` | Mindestens 32 Zeichen |

Jeder andere Schlüssel oder ein Wert, der eine Regel verletzt, hält die Dienste gestoppt, und nichts Provisioniertes wird geschrieben. Korrigiere die Provisionierungsdaten und starte neu.

`ERASURE_TOMBSTONE_SALT`, `FERNET_KEY` und `ARANGODB_PASSWORD` [dürfen sich nicht ändern](configuration.md#werte-die-sich-nicht-andern-durfen), sobald ein Dienst damit gestartet ist. Ein provisionierter Wert eines davon stellt einen fehlenden Schlüssel nur wieder her, wenn er dem Wert entspricht, mit dem Kamerplanter gestartet ist; sonst bleiben die Dienste gestoppt, bis du den Schlüssel aus deinem Backup wiederherstellst.

Die Appliance hat kein Kommando, das Secrets rotiert. Um eines später zu ändern, setze es in `/etc/kamerplanter/kamerplanter.env`; eine Änderung der Map derselben Instanz wirkt nicht.

## Secrets als System-Credentials { #secrets-as-system-credentials }

Auf Proxmox VE und jedem anderen QEMU-Gast kann ein Secret auch als System-Credential `kamerplanter.secret.<KEY>` kommen, eines je Schlüssel, zum Beispiel als SMBIOS-Typ-11-Zeichenkette:

```bash
-smbios type=11,value=io.systemd.credential:kamerplanter.secret.JWT_SECRET_KEY=4f0c7d9e2b1a8c6e5d3f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d
```

Auf Proxmox VE trägst du dasselbe als `args:` in die VM-Konfiguration ein:

```text
args: -smbios type=11,value=io.systemd.credential:kamerplanter.secret.JWT_SECRET_KEY=4f0c7d9e2b1a8c6e5d3f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d
```

Nur `root@pam` darf `args` setzen.

Übergib ein Secret nicht mit `systemd.set_credential=` auf der Kernel-Kommandozeile: Jeder lokale Nutzer und jeder Container kann `/proc/cmdline` lesen.

Ein Credential wird bei jedem Boot gelesen und füllt einen Schlüssel, den `secrets.env` nicht enthält, mit denselben Schlüsseln und Regeln wie die Map. Liefern ein Credential und die Map denselben fehlenden Schlüssel, gewinnt das Credential.

!!! warning "Credentials bleiben lesbar"
    Ein SMBIOS-Credential bleibt für root lesbar, solange die Appliance läuft, in `/sys/firmware/dmi/tables/` und in `/run/credentials/@system/`. Es liegt außerdem im Klartext in der VM-Konfiguration. Entferne es aus der VM, sobald das Secret übernommen ist.

## Schutz { #protection }

**Die Kopien von cloud-init werden gelöscht.** cloud-init speichert die User-Data und jedes Secret darin bei jedem Boot erneut, solange die Quelle angeschlossen ist. Bei jedem Boot, nachdem die Einstellungen erneuert und die Secrets übernommen sind, löscht die Appliance `user-data.txt`, `user-data.txt.i`, `cloud-config.txt` und `obj.pkl` in jedem Verzeichnis unter `/var/lib/cloud/instances/` sowie `combined-cloud-config.json` und `instance-data-sensitive.json` in `/run/cloud-init/`. Vorher ersetzt sie jedes provisionierte Secret durch `REDACTED` in dem, was dort liegt, und in den Logs von cloud-init `/var/log/cloud-init*.log`, auch in rotierten; ein komprimiertes Log mit einem Secret wird gelöscht. Die Kopien kommen zuletzt dran: Endet ein Boot vorzeitig, bleiben sie liegen, und der nächste Boot findet die Secrets darin, auch wenn die Quelle dann fehlt. Die Secrets werden aus jeder Kopie gelesen, die sich lesen lässt; lässt sich keine Kopie einer Instanz lesen, werden stattdessen die Logs von cloud-init gelöscht und die Fehlermeldungen im Status von cloud-init durch `REDACTED` ersetzt. Ein Wert unter 8 Zeichen wird nicht gesucht; die Meldung nennt seinen Schlüssel. Die Aufzeichnung von cloud-init über die Instanz bleibt erhalten, sodass Schritte, die einmal je Instanz laufen, nicht erneut laufen. Das Ergebnis steht in:

```bash
systemctl status kamerplanter-cloud-init-scrub
```

Seed-Dateien unter `/var/lib/cloud/seed/` sind deine Quelle, keine Kopie, und bleiben unberührt. Enthalten sie ein Secret, warnt die Appliance. Das Verzeichnis ist nur für root lesbar.

Die Appliance kann nur Secrets ersetzen, die sie in der von cloud-init gelesenen User-Data findet. Ist die User-Data kein gültiges YAML, etwa weil ein Secret, das mit `*`, `&` oder `@` beginnt, nicht in Anführungszeichen steht, liest cloud-init nichts davon und kann die fehlerhafte Zeile in seinem Log und im Journal zitieren, wo sie bleibt. Setze jedes Secret in Anführungszeichen.

**Nur root erreicht den Metadatendienst.** Die Adresse `169.254.169.254` gibt die Provisionierungsdaten samt Secrets an jeden heraus, der fragt. Nur root erreicht sie, schon bevor der erste Container startet. Andere lokale Nutzer und die Container erreichen sie nicht, und die Container erreichen auch keine andere Link-Local-Adresse (`169.254.0.0/16`). Antworten an einen Client, der selbst eine Link-Local-Adresse hat, erreichen ihn weiterhin. Die Appliance maskiert `nftables.service`, dessen Neuladen und Stoppen diese Regeln entfernen würde, und lädt sie jede Minute neu, sodass sie innerhalb einer Minute wieder gelten, wenn etwas anderes sie entfernt oder ändert. Eine Host-Firewall über `nftables.service` steht deshalb nicht zur Verfügung; nach dem Update, das die Maske einführt, lädt ein Gerät, auf dem sie aktiviert war, `/etc/sysconfig/nftables.conf` nicht mehr.

## Nach dem ersten Boot { #after-the-first-boot }

Provisionierungsdaten liegen im Klartext, bis du sie löschst; bei Hetzner Cloud und OVHcloud bewahrt der Anbieter sie für die Lebensdauer des Servers auf. Sobald die Appliance gestartet ist:

1. Entferne das NoCloud-Laufwerk, oder lösche die Seed-Dateien und deine Datei in `/etc/cloud/cloud.cfg.d/`. Die Einstellungen und Secrets bleiben in Kraft.
2. Lösche Provisionierungsdaten, die Secrets enthalten, etwa Snippets auf Proxmox VE, und entferne Secret-Credentials aus der VM-Konfiguration.

## Erwarteter Status von cloud-init { #expected-cloud-init-status }

```bash
cloud-init status
```

meldet `degraded done` und endet mit dem Code 2. Die Ursache ist der Schlüssel `kamerplanter:`, den cloud-init nicht kennt. Das ist kein Fehler; keine Unit und keine Prüfung der Appliance behandelt es als einen.

!!! warning "Bleib innerhalb dieser Schnittstelle"
    Das Root-Dateisystem ist unveränderlich und wird mit jedem Update ersetzt. cloud-init-Funktionen jenseits dieser Seite, etwa Module, die Pakete installieren oder unter `/usr` schreiben, können Updates und Rollbacks stören.
