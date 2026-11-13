# Anforderungen an die Distribution

Status: draft

## Kontext

Die Kamerplanter-Appliance wird als bootfähiges Image ausgeliefert, das ein Betriebssystem installiert und darauf die Kamerplanter-Container ausführt (siehe `README.md` des Repositorys). Das Betriebssystem darunter ist Mittel zum Zweck und kein Produkt: Der Nutzer soll es weder bemerken noch pflegen müssen. Dieses Spec legt fest, was eine Basis-Distribution dafür leisten muss. Es nennt keine Distribution, damit jeder Kandidat an derselben Liste gemessen wird und sich die spätere Wahl Anforderung für Anforderung begründen lässt.

Die Anforderungen leiten sich aus den Projektzielen in `README.md` und aus der Release-Compose-Datei des Hauptprojekts ab. Festgestellt durch Lesen von `docker-compose.release.yml` in einer Arbeitskopie von `nolte/kamerplanter` am 2026-11-12: Die Web-UI wird auf Port 8080 und die API auf Port 8000 veröffentlicht, beide gebunden an `${KAMERPLANTER_BIND_ADDRESS:-127.0.0.1}` (Zeilen 153 und 242); die veröffentlichten Ports der Datenbanken und von Ollama binden an `127.0.0.1` (Zeilen 29, 62, 83, 103) [R1].

Festgestellt am 2026-11-12 durch eine Sichtung der Dokumentation, Paketmanifeste, Kernel-Konfigurationen und Release-Artefakte der Kandidaten über Recherche-Agenten; nichts wurde installiert, gebootet oder gemessen:

| Punkt | `bootc` auf Fedora oder CentOS Stream [R2][R3][R4][R5][R6] | Flatcar Container Linux [R7][R8] | openSUSE MicroOS, Leap Micro [R9][R10][R11] |
|-------|------------------|-------------------------|------------------------------|
| Ein versioniertes Image (A2) | Ja, ein OCI-Image mit Digest | Ja, ein versioniertes `/usr`-Image | Nein, paketbasiert ohne Image-Kennung |
| Automatisches atomares Update (B1, B2) | Ja; das Neustartfenster braucht einen Timer-Override | Ja, mit Neustartfenstern | Ja, mit Neustartfenstern |
| Rollback bei eigenem Health-Check (B3) | Über greenboot, ein Zusatzpaket, das die bootc-Dokumentation nicht behandelt | Dokumentiertes Rezept aus mehreren Units | Natives Plugin-Verzeichnis von health-checker |
| Container, Konfiguration und Baseline kommen mit dem System-Update (B7, B9, K3) | Ja, sie sind Teil des Images | Nein, nur das System aktualisiert sich; der Rest ist selbst zu bauen | Nur über eine eigene Paketquelle |
| Neustart bei Ende und bei unhealthy, Reihenfolge, geordnetes Stoppen (C11, C12, C13) | Nativ mit Podman und systemd | Neustart bei Ende nativ; unhealthy braucht einen eigenen Wächter | Nativ mit Podman und systemd |
| Upstream-Compose-Datei direkt nutzbar (C8) | Nein; Übersetzung in systemd-Units | Nur über eine Community-Erweiterung, die Flatcar nicht testet | Über Zusatzpakete, ohne die systemd-Überwachung |
| Gleicher Inhalt auf jedem Ziel (deployment-targets H10) | Ja, mit ins Image aufgenommenem cloud-init | Identisches System, eine kleine Variante je Ziel | Nur mit einem eigenen Image-Profil |
| Installer-ISO (D1, D2) | Möglich; das Werkzeug ist im Umbruch | Das offizielle ISO ist ein Live-System nur für BIOS; ein eigener Installer ist nötig | Unbeaufsichtigtes Self-Install-ISO aus demselben Build wie das Raw-Image |
| Legacy-BIOS und UEFI (deployment-targets H4) | Hybrides Partitionslayout, nicht als unterstützt zugesagt | Beide Bootloader im selben Image | MicroOS nur in der GRUB2-Variante; SUSE dokumentiert Micro 6.2 als nur UEFI |
| Geräte, die Proxmox VE standardmäßig zuweist (deployment-targets H3) | Fedora baut beide Treiber; CentOS Stream baut den LSI-Treiber nicht | Beide Treiber liegen in der initrd des Releases | Nicht dokumentiert |
| Mandatory Access Control erzwingend (G5) | Ja | Nein, standardmäßig permissive, mit Einschränkungen bei geteilten Volumes | Ja |
| Firewall mit Default-Deny (G1) | Zu ergänzen | Zu ergänzen | In MicroOS zu ergänzen |
| Support-Lebenszyklus (I1) | Fedora etwa 13 Monate je Release; CentOS Stream 10 bis 2030-05-31 | Ein Stable-Kanal ohne feste Enddaten, ein LTS-Kanal mit 18 Monaten | MicroOS rollend; der Status von Leap Micro ist unklar |

Festgestellt am 2026-11-13 aus der Upstream-Dokumentation (`docs/de/deployment/konfigurationsmatrix.md`, `docs/de/reference/environment-variables.md`, `docs/de/deployment/backup-restore.md` in einer Arbeitskopie von `nolte/kamerplanter`) und aus den ersten Prototyp-Läufen: Mit `DEBUG=false` verweigert das Backend den Start ohne `JWT_SECRET_KEY`, `ARANGODB_PASSWORD`, `FERNET_KEY`, `ERASURE_TOMBSTONE_SALT` und `LOG_PSEUDONYM_SALT`, während die Upstream-Datei `.env.example` nur das Datenbankpasswort und die beiden Salts nennt und die Release-Compose-Datei weder `JWT_SECRET_KEY` noch `FERNET_KEY` durchreicht. Die Upstream-Dokumentation sagt, dass `ERASURE_TOMBSTONE_SALT` sich nie ändern darf und dass mit `FERNET_KEY` verschlüsselte Daten und Löschnachweise nach einer Wiederherstellung von diesen Werten abhängen. Ein Versuch mit dem gepinnten ArangoDB-Image zeigte, dass es `ARANGO_ROOT_PASSWORD` nur beim ersten Anlegen der Datenbank übernimmt: Nach einem Neustart mit anderem Wert meldet sich das alte Passwort weiter an, das neue wird abgelehnt.

Nicht festgestellt: alles, was die Akzeptanzkriterien von einem Prototyp verlangen, insbesondere Boot und Rollback unter Legacy-BIOS, die tatsächlich in der initialen RAM-Disk vorhandenen Treiber, das Verhalten bei Stromausfall und der Fußabdruck. Für openSUSE ließen sich die Seiten zu Lizenz, Marke und Lebensdauer nicht abrufen, und Teile der MicroOS-Befunde stammen aus einem Drittanbieter-Spiegel der Image-Beschreibung.

Abgrenzung: Das Verhalten der Anwendung gehört zu `nolte/kamerplanter`. Wo die Appliance läuft und was sich zwischen diesen Orten unterscheidet, legt `spec/deployment-targets/` fest. Die Build-Pipeline, der Update-Kanal samt Release-Prozess und die Oberfläche der Ersteinrichtung sind Gegenstand eigener Specs, die es noch nicht gibt. Dieses Spec hält nur fest, was die Distribution dafür ermöglichen muss.

Leser: Maintainer, die die Basis-Distribution auswählen und die Appliance bauen, sowie Reviewer, die einen Kandidaten bewerten.

## Ziele

- Eine Kandidaten-Distribution lässt sich anhand einer festen, prüfbaren Liste annehmen oder ablehnen.
- Der Betrieb der Appliance erfordert keine Systemadministration: Der Nutzer patcht, verwaltet Betriebssystem-Benutzer, härtet oder repariert das Betriebssystem nie von Hand.
- Updates sind so einfach wie möglich: Sie geschehen von selbst, und ein fehlgeschlagenes Update macht sich selbst rückgängig.
- Das System enthält nichts, was der Betrieb der Container nicht braucht: kein grafisches System, keinen Desktop, keine Entwicklungswerkzeuge.

## Nicht-Ziele

- Die Auswahl der Distribution. Sie ist eine offene Frage, die dieses Spec vorbereitet.
- Die Spezifikation der Build-Pipeline, des Release-Prozesses oder der Einrichtungsoberfläche.
- Anforderungen an die Kamerplanter-Dienste selbst.
- Mehrknotenbetrieb, Clustering oder Hochverfügbarkeit.
- Hardwareunterstützung über die in `spec/deployment-targets/` genannten Referenzziele hinaus.

## Anforderungen

### A. Unveränderliches System-Image

- **A1 MUSS [MUST]** den Betriebssystembaum (Kernel, Userland, Container-Runtime) im Normalbetrieb schreibgeschützt einhängen.
- **A2 MUSS [MUST]** das System als ein versioniertes Image ausliefern und identifizieren, sodass zwei Installationen derselben Version identischen Systeminhalt haben.
- **A3 MUSS [MUST]** die Appliance gepatcht und lauffähig halten, ohne dass der Nutzer je einen Paketmanager aufruft.
- **A4 MUSS [MUST]** lokale Konfiguration auf eine deklarierte Menge beschreibbarer Orte beschränken.
- **A5 SOLLTE [SHOULD]** die Integrität des System-Images beim Boot oder bei der Aktivierung eines Updates prüfen.

### B. Updates

- **B1 MUSS [MUST]** das Betriebssystem und die Kamerplanter-Container ohne Nutzereingriff aktualisieren: ohne Kommando, ohne Anmeldung und ohne Entscheidung.
- **B2 MUSS [MUST]** Updates atomar anwenden: Ein Update wird entweder vollständig aktiv oder lässt die laufende Version unberührt, auch bei Stromausfall zu jedem Zeitpunkt.
- **B3 MUSS [MUST]** automatisch zur vorherigen Version zurückkehren, wenn die neue Version nicht bootet oder einen von der Appliance deklarierten Health-Check nicht besteht.
- **B4 MUSS [MUST]** mindestens die zuvor laufende Version installiert und bootfähig halten.
- **B5 MUSS [MUST]** der Appliance die Kontrolle darüber geben, wann der aktivierende Neustart erfolgt.
- **B6 MUSS [MUST]** die kryptografische Authentizität eines Updates vor der Aktivierung prüfen.
- **B7 DARF NICHT [MUST NOT]** vom Nutzer verlangen, Betriebssystem- und Container-Versionen aufeinander abzustimmen: Jede Kombination, die der Update-Mechanismus erzeugen kann, funktioniert oder wird zurückgerollt.
- **B8 SOLLTE [SHOULD]** den Update-Mechanismus nutzen, den die Distribution bereitstellt und pflegt, mit möglichst wenigen Komponenten, die dieses Projekt selbst bauen oder betreiben muss.
- **B9 SOLLTE [SHOULD]** Betriebssystem und Container-Images in einem Update führen, sodass nur gemeinsam veröffentlichte Kombinationen je laufen.
- **B10 SOLLTE [SHOULD]** Updates aus einer Quelle annehmen, die dieses Projekt kontrolliert, sodass ein fehlerhaftes Update zurückgehalten werden kann.
- **B11 SOLLTE [SHOULD]** nur die geänderten Teile eines Images übertragen statt des vollständigen Images.
- **B12 KANN [MAY]** einen manuellen Update-Auslöser und einen manuellen Rollback auf der Konsole anbieten.

### C. Container-Workload

- **C1 MUSS [MUST]** eine OCI-Container-Runtime im System-Image enthalten, die von der Distribution gepflegt wird.
- **C2 MUSS [MUST]** die veröffentlichten Upstream-Container-Images unverändert ausführen.
- **C3 KANN [MAY]** die Container-Images beim ersten Start aus einer Registry laden, statt sie im ausgelieferten Artefakt mitzuführen.
- **C4 MUSS [MUST]** jedes Container-Image per Digest referenzieren.
- **C5 MUSS [MUST]** die Container mit den Mitteln der Distribution selbst steuern, ihrem Service-Manager und ihrer Container-Runtime, ohne zusätzlichen Orchestrator.
- **C6 DARF NICHT [MUST NOT]** Kubernetes oder eine andere Cluster-Control-Plane voraussetzen.
- **C7 MUSS [MUST]** jede Übersetzung der Upstream-Compose-Definition im Build erzeugen und prüfen, falls die Runtime diese Definition nicht direkt verarbeiten kann.
- **C8 SOLLTE [SHOULD]** die Upstream-Compose-Definition ohne Übersetzung verarbeiten.
- **C9 MUSS [MUST]** erlauben, die optionalen Dienste (`vectordb`, `ollama`, `timescaledb`) nach der Installation zu aktivieren, ohne das System-Image zu verändern.
- **C10 MUSS [MUST]** die Container bei jedem späteren Boot aus den bereits geladenen Images starten, ohne Zugriff auf eine Registry.
- **C11 MUSS [MUST]** einen Container automatisch neu starten, wenn er sich beendet oder als unhealthy gemeldet wird.
- **C12 MUSS [MUST]** nach jedem Neustart der Maschine, geplant oder ungeplant, alle Container ohne Nutzereingriff in der erforderlichen Reihenfolge hochfahren.
- **C13 MUSS [MUST]** die Container beim Herunterfahren geordnet stoppen, sodass die Datenbanken sauber schließen.

### D. Installation und erster Boot

- **D1 MUSS [MUST]** sich von einem bootfähigen ISO auf die Festplatte einer VM oder eines x86_64-Mini-PCs installieren lassen.
- **D2 MUSS [MUST]** die Installation mit nicht mehr Nutzereingabe abschließen als der Bestätigung der Zielfestplatte.
- **D3 SOLLTE [SHOULD]** eine vollständig unbeaufsichtigte Installation anhand einer mitgelieferten Konfiguration unterstützen.
- **D4 MUSS [MUST]** beim ersten Boot maschinenlesbare Provisionierungsdaten für Hostname, Netzwerk und einen Administrator-SSH-Schlüssel annehmen.
- **D5 MUSS [MUST]** einen Hook bereitstellen, der beim ersten Boot einen einmaligen Schritt ausführt, bevor die Container starten.
- **D6 DARF NICHT [MUST NOT]** voreingestellte Zugangsdaten für ein Betriebssystemkonto oder einen Dienst ausliefern.
- **D7 MUSS [MUST]** das Netzwerk standardmäßig per DHCP konfigurieren und eine statische Konfiguration erlauben.
- **D8 MUSS [MUST]** sich als vorinstalliertes Image ausliefern lassen, das direkt von dem Medium bootet, auf das es geschrieben wurde, für Ziele ohne Installer-Schritt.
- **D9 MUSS [MUST]** jedes Secret, das die Kamerplanter-Dienste verlangen, je Installation einzeln erzeugen und über Updates und Rollbacks hinweg behalten.
- **D10 MUSS [MUST]** ein Secret, das ein späteres Release neu verlangt, beim ersten Boot dieses Releases ohne Nutzereingriff erzeugen.
- **D11 MUSS [MUST]** dem Nutzer erlauben, jedes erzeugte Secret und jede Einstellung der Dienste vor oder nach dem ersten Start in einer dokumentierten Datei zu überschreiben, die Updates und Rollbacks überdauert.
- **D12 MUSS [MUST]** die wirksame Konfiguration prüfen, bevor die Dienste starten, und sie mit einer Meldung, die den fehlerhaften Wert nennt, gestoppt lassen, wenn ein Wert ungültig ist oder sich ein Wert geändert hat, der nach dem ersten Start gleich bleiben muss.

### E. Zustand und Daten

- **E1 MUSS [MUST]** allen persistenten Zustand an einem vom System-Image getrennten Ort halten, den Updates und Rollbacks nicht berühren.
- **E2 MUSS [MUST]** die Menge der persistenten Orte aufzählbar machen, sodass alles außerhalb davon verworfen und reproduziert werden kann.
- **E3 MUSS [MUST]** den Datenort auf den verfügbaren Platz wachsen lassen, beim ersten Boot und nach dem Vergrößern einer virtuellen Festplatte, ohne Neuinstallation.
- **E4 SOLLTE [SHOULD]** auf virtualisierten Zielen konsistente Backups über Hypervisor-Snapshots unterstützen, einschließlich eines Dateisystem-Freeze über einen Gast-Agenten.
- **E5 MUSS [MUST]** die erzeugten Secrets im persistenten Zustand halten und in der Backup-Anleitung nennen, weil Daten, die ohne sie wiederhergestellt werden, ihre verschlüsselten Felder und Löschnachweise verlieren.

### F. Fußabdruck

- **F1 MUSS [MUST]** nur die Komponenten enthalten, die zum Booten, Aktualisieren, Ausführen der Container und zur Diagnose nötig sind.
- **F2 DARF NICHT [MUST NOT]** ein grafisches System wie X11 oder Wayland, eine Desktop-Umgebung oder grafische Anwendungen enthalten.
- **F3 DARF NICHT [MUST NOT]** Compiler oder Entwicklungs-Toolchains enthalten.
- **F4 DARF NICHT [MUST NOT]** einen Dienst ausführen, den die Appliance nicht nutzt.
- **F5 MUSS [MUST]** für jedes Release die installierten Komponenten auflisten, sodass F1 bis F4 prüfbar sind.
- **F6 MUSS [MUST]** für jeden bewerteten Kandidaten in Speicherverbrauch im Leerlauf, installierter Größe und Bootzeit gemessen und dokumentiert sein.
- **F7 SOLLTE [SHOULD]** bei sonst gleichwertigen Kandidaten der Kandidat mit dem kleineren Fußabdruck sein.

### G. Netzwerk und Sicherheit

- **G1 MUSS [MUST]** eingehende Verbindungen standardmäßig ablehnen und nur die Web-UI (8080), die API (8000) und ausdrücklich aktivierten administrativen Zugang öffnen.
- **G2 MUSS [MUST]** Datenbank- und Broker-Ports von außerhalb der VM unerreichbar halten.
- **G3 MUSS [MUST]** administrativen Fernzugang deaktiviert halten, bis der Nutzer einen Schlüssel hinterlegt, und nie eine Passwortanmeldung zulassen.
- **G4 MUSS [MUST]** die Systemuhr synchronisieren.
- **G5 SOLLTE [SHOULD]** Container mit einem erzwingenden Mandatory-Access-Control-System einschränken.
- **G6 MUSS [MUST]** Sicherheitskorrekturen für Kernel, Basissystem und Container-Runtime von einer Distribution mit öffentlichem Advisory-Prozess erhalten.
- **G7 MUSS [MUST]** die Web-UI und die API über TLS ausliefern können, wie `spec/deployment-targets/` §F es für gehostete VMs verlangt.
- **G8 MUSS [MUST]** eine Quelladresse nach wiederholt fehlgeschlagenen Anmeldungen an der Web-UI, der API oder dem administrativen Zugang automatisch sperren, durch einen Mechanismus wie fail2ban.
- **G9 MUSS [MUST]** die Rate neuer Verbindungen und Anfragen je Quelladresse begrenzen, sodass eine Flut aus wenigen Quellen die Appliance für andere nicht unerreichbar macht.
- **G10 MUSS [MUST]** eine automatische Sperre nach begrenzter Zeit ohne Nutzereingriff aufheben.
- **G11 MUSS [MUST]** die Schutzmechanismen aus G8 und G9 aktiviert und vorkonfiguriert ausliefern, als Teil der Sicherheits-Baseline aus §K.
- **G12 SOLLTE [SHOULD]** dem Nutzer erlauben, eigene Adressen von der Sperre auszunehmen und die Schwellenwerte zu ändern.

### H. Zielplattformen und Artefakte

- **H1 MUSS [MUST]** auf jedem in `spec/deployment-targets/` genannten Referenzziel laufen: als KVM-Gast mit virtio-Speicher- und -Netzwerkgeräten und auf x86_64-Mini-PCs.
- **H2 MUSS [MUST]** unter der Firmware booten, die jedes Referenzziel standardmäßig anbietet.
- **H3 MUSS [MUST]** alle Auslieferungsartefakte einer Architektur aus derselben Quelldefinition mit identischem Systeminhalt erzeugen.
- **H4 MUSS [MUST]** in der CI ohne interaktive Schritte und mit gepinnten Eingaben bauen.
- **H5 SOLLTE [SHOULD]** reproduzierbar bauen: Dieselben Eingaben ergeben denselben Systeminhalt.
- **H6 SOLLTE [SHOULD]** auf virtualisierten Zielen einen QEMU-Gast-Agenten enthalten.
- **H7 KANN [MAY]** aarch64 unterstützen.
- **H8 SOLLTE [SHOULD]** die Treiber und Bootmodi bereitstellen, die die geplanten Ziele in `spec/deployment-targets/` verlangen, sodass ihre Anbindung keinen Wechsel der Basis-Distribution erfordert.

### I. Tragfähigkeit der Basis

- **I1 MUSS [MUST]** aktiv gepflegt sein und einen dokumentierten Support-Lebenszyklus haben.
- **I2 MUSS [MUST]** die Weitergabe des gebauten Images kostenlos und ohne Subskription erlauben.
- **I3 MUSS [MUST]** mit frei verfügbaren Werkzeugen baubar sein.
- **I4 SOLLTE [SHOULD]** Hauptversions-Upgrades der Basis über denselben Update-Mechanismus ausliefern, ohne Neuinstallation.

### J. Betreibbarkeit

- **J1 MUSS [MUST]** System- und Container-Logs an einer Stelle mit begrenztem Plattenverbrauch verfügbar machen.
- **J2 MUSS [MUST]** die laufende Version und den Update-Zustand maschinenlesbar bereitstellen.
- **J3 SOLLTE [SHOULD]** erlauben, dass die Konsole nach dem Boot die Appliance-Version und die Adresse der Web-UI anzeigt.

### K. Betriebsaufwand

- **K1 MUSS [MUST]** ohne ein Betriebssystem-Benutzerkonto auskommen, das der Nutzer anlegen oder pflegen muss.
- **K2 MUSS [MUST]** seine Sicherheits-Baseline als Teil des System-Images ausliefern, sodass der Nutzer keine Härtung vornimmt.
- **K3 MUSS [MUST]** Änderungen an der Baseline über den Update-Mechanismus aus §B ausliefern und über keinen anderen Kanal.
- **K4 MUSS [MUST]** wiederkehrende Wartung wie Log-Rotation, das Entfernen abgelöster Images und die Uhrensynchronisation ohne Nutzereingriff ausführen.
- **K5 SOLLTE [SHOULD]** die Baseline durch eine automatisierte Prüfung verifizierbar machen, die im Build läuft.

## Akzeptanzkriterien

Jedes Kriterium wird an einem Prototyp des Kandidaten geprüft. Die Kriterien fassen mehrere Anforderungen zusammen; jede Anforderung bleibt für sich normativ.

- [ ] Ein Schreibzugriff auf einen Systempfad schlägt auf der installierten Appliance fehl (A1).
- [ ] Zwei Installationen derselben Version melden dieselbe System-Image-Kennung (A2).
- [ ] Ein Update, das während der Bereitstellung durch Stromausfall unterbrochen wird, und eines, das während der Aktivierung unterbrochen wird, booten jeweils in eine konsistente Version (B2).
- [ ] Ein Update auf eine Version mit absichtlich fehlschlagendem Health-Check endet ohne Nutzereingriff und mit unversehrten Daten auf der vorherigen Version (B3, B4, E1).
- [ ] Ein Update des Betriebssystems und der Container läuft ohne Kommando, Anmeldung oder Entscheidung des Nutzers durch, und sein Neustart erfolgt zu dem von der Appliance konfigurierten Zeitpunkt (B1, B5).
- [ ] Ein Update mit ungültiger Signatur wird abgelehnt (B6).
- [ ] Nach jedem Update und jedem Rollback besteht die laufende Kombination aus Betriebssystem- und Container-Versionen den Health-Check, ohne dass der Nutzer eine der Versionen gewählt hat, und jeder laufende Container ist per Digest referenziert (B7, C4).
- [ ] Die Komponenten, die dieses Projekt für das Aktualisieren baut oder betreibt, sind aufgelistet, und jede ist gegenüber dem Mechanismus der Distribution begründet (B8).
- [ ] Installation und erster Start auf einer VM mit Internetzugang enden mit allen Core-Containern im Zustand healthy, und ein Neustart dieser VM ohne Netzwerkzugang endet ebenso (C2, C10, D1).
- [ ] Ein beendeter Core-Container und ein als unhealthy gemeldeter werden jeweils ohne Nutzereingriff vom Service-Manager der Distribution neu gestartet, und es ist keine Kubernetes-Komponente vorhanden (C5, C6, C11).
- [ ] Nach einem geplanten Neustart und nach einem harten Reset der Maschine erreichen alle Core-Container in der erforderlichen Reihenfolge den Zustand healthy, und die Web-UI antwortet, ohne Nutzereingriff und ohne Datenverlust (C12, C13).
- [ ] Ein optionaler Dienst wird auf einer installierten Appliance aktiviert, während die System-Image-Kennung unverändert bleibt (C9).
- [ ] Eine ISO-Installation auf Proxmox VE braucht keine Eingabe außer der Zielfestplatte und endet damit, dass die Web-UI auf Port 8080 antwortet (D1, D2, D7, H1, H2).
- [ ] Ein aus einem Appliance-Artefakt erzeugter Hetzner-Cloud-Server endet damit, dass die Web-UI auf Port 8080 antwortet (H1, H2, H3).
- [ ] Das auf ein USB-Medium geschriebene ISO installiert einen x86_64-Mini-PC, und die Web-UI antwortet auf Port 8080 (D1, H1, H2).
- [ ] Das vorinstallierte Image, auf die Festplatte einer VM geschrieben, bootet direkt, und alle Core-Container erreichen den Zustand healthy (D8).
- [ ] Als Provisionierungsdaten übergebene Werte für Hostname und SSH-Schlüssel sind nach dem ersten Boot wirksam (D4).
- [ ] Zwei frische Installationen enthalten unterschiedliche generierte Secrets, und kein Konto akzeptiert ein voreingestelltes Passwort (D5, D6).
- [ ] Ein Portscan von außerhalb der VM findet nur 8080 und 8000, dazu SSH nur, wenn ein Schlüssel hinterlegt wurde (G1, G2, G3).
- [ ] Wiederholt fehlgeschlagene Anmeldungen von einer Adresse an der Web-UI und am administrativen Zugang führen zur Sperre dieser Adresse, und die Sperre endet nach der konfigurierten Zeit, ohne Nutzereingriff (G8, G10).
- [ ] Während eine Quelle die Appliance mit Verbindungen flutet, erhält eine zweite Quelle weiterhin Antworten von der Web-UI (G9).
- [ ] Auf einer frischen Installation sind Sperre und Ratenbegrenzung ohne jede Konfiguration aktiv, und die Web-UI antwortet über TLS (G7, G11).
- [ ] Der Datenort umfasst nach dem ersten Boot den verfügbaren Platz und bietet nach dem Vergrößern einer virtuellen Festplatte den zusätzlichen Platz ohne Neuinstallation (E3).
- [ ] Alle Auslieferungsartefakte einer Architektur aus einem CI-Lauf melden dieselbe System-Image-Kennung (H3, H4).
- [ ] Die persistenten Orte sind aufgelistet, und die Appliance nimmt den Betrieb wieder auf, nachdem alles außerhalb davon verworfen wurde (A4, E2).
- [ ] Eine frische Installation startet mit jedem Secret, das die Dienste verlangen, und ein aus der erzeugten Menge entferntes Secret wird beim nächsten Boot erneut erzeugt (D9, D10).
- [ ] Ein in der Nutzerdatei gesetzter Wert erreicht die Dienste nach einem Neustart, gewinnt gegenüber dem erzeugten Wert und gilt nach einem Update und nach einem Rollback weiter (D11).
- [ ] Ein ungültiger Wert in der Nutzerdatei und ein geänderter Wert einer Einstellung, die gleich bleiben muss, halten die Dienste mit einer Meldung gestoppt, die den Wert nennt (D12).
- [ ] Die Backup-Anleitung nennt die erzeugten Secrets, und eine Wiederherstellung mit ihnen bringt verschlüsselte Felder zurück (E5).
- [ ] Die Komponentenliste des Releases enthält kein grafisches System, keine Desktop-Umgebung und keine Entwicklungs-Toolchain, und es läuft kein Dienst, den die Appliance nicht nutzt (F1, F2, F3, F4, F5).
- [ ] Speicherverbrauch im Leerlauf, installierte Größe und Bootzeit sind für den Kandidaten dokumentiert (F6).
- [ ] Support-Lebenszyklus, Advisory-Prozess und Weitergabebedingungen sind mit ihren Quellen dokumentiert (G6, I1, I2, I3).
- [ ] Laufende Version und Update-Zustand werden über eine dokumentierte maschinenlesbare Schnittstelle gelesen, und die Logs bleiben innerhalb ihrer konfigurierten Größe (J1, J2).
- [ ] Eine installierte Appliance durchläuft einen Update-Zyklus, ohne dass sich jemand am Betriebssystem anmeldet, ein Konto anlegt oder eine Systemeinstellung ändert (A3, K1, K4).
- [ ] Die Baseline-Prüfung besteht im Build und auf einer installierten Appliance, und eine Baseline-Änderung erreicht eine installierte Appliance über ein Update (K2, K3, K5).
- [ ] Für jedes geplante Ziel sind die Treiber und Bootmodi, die seine Dokumentation verlangt, im Image vorhanden oder als fehlend vermerkt (H8).

## Referenzen

- Quellen abgerufen am 2026-11-12.
- [R1] `docker-compose.release.yml` in `nolte/kamerplanter` (P): <https://github.com/nolte/kamerplanter/blob/develop/docker-compose.release.yml>
- [R2] bootc-Dokumentation, Release v1.17.4 (P): <https://github.com/bootc-dev/bootc/tree/main/docs/src>
- [R3] Fedora/CentOS-bootc-Dokumentation, zuletzt geändert am 2026-04-07 (P): <https://docs.fedoraproject.org/en-US/bootc/>
- [R4] image-builder, Migration von bootc-image-builder, v90.0.0 (P): <https://github.com/osbuild/image-builder/blob/main/doc/20-advanced/20-bootc/50-migration.md>
- [R5] greenboot-rs README, v0.16.5 (P): <https://github.com/fedora-iot/greenboot-rs/blob/main/README.md>
- [R6] Podman-Dokumentation, `podman-systemd.unit(5)` (P): <https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html>
- [R7] Dokumentation von Flatcar Container Linux (P): <https://www.flatcar.org/docs/latest/>
- [R8] Flatcar-Release-Artefakte, Stable 4757.2.3 (P): <https://stable.release.flatcar-linux.net/amd64-usr/4757.2.3/>
- [R9] Handbuch zu transactional-update, Version 6.2.0 (P): <https://github.com/openSUSE/transactional-update/blob/master/man/transactional-update.8.xml>
- [R10] health-checker README (P): <https://github.com/openSUSE/health-checker>
- [R11] SUSE Linux Micro 6.2, Deployment-Images, veröffentlicht am 2026-10-29 (P): <https://documentation.suse.com/sle-micro/6.2/html/Micro-deployment-images/index.html>

## Offene Fragen

- **Welche Distribution die Basis ist.** Die Dokumentensichtung im Kontext spricht für `bootc`: Es ist der einzige Kandidat, bei dem die Definitionen der Container, die Konfiguration und die Sicherheits-Baseline mit dem System-Update reisen und mit ihm zurückrollen und bei dem ein Image jedes Ziel bedient. Seine bekannten Risiken sind der Rollback, der auf einem Zusatzpaket beruht und unter Legacy-BIOS nicht verifiziert ist, das Werkzeug für das Installer-ISO im Umbruch und der Umfang eigener Konfiguration im Image. Flatcar ist auf der Ebene des Betriebssystems am stärksten und überlässt alles darüber diesem Projekt; MicroOS hat kein versioniertes Image. Die Entscheidung bleibt offen, bis ein Prototyp die nicht festgestellten Punkte beantwortet hat, einschließlich der Wahl zwischen Fedora und CentOS Stream als Basis von `bootc`.
- **Zahlenwerte für den Fußabdruck.** F6 verlangt Messungen, setzt aber keine Grenze, weil der Ressourcenverbrauch der Core-Dienste selbst nicht gemessen ist und eine Grenze für die Basis ohne ihn willkürlich wäre.
- **Firmware je Ziel.** H2 verweist auf die Standard-Firmware jedes Referenzziels. `spec/deployment-targets/` §H hält fest, dass Proxmox VE standardmäßig SeaBIOS nutzt, dass Hetzner und OVH ihre Firmware nicht dokumentieren und dass das Image deshalb unter Legacy-BIOS und unter UEFI booten muss. Welche Kandidaten das zusammen mit dem Rollback aus §B bieten, ist nicht geprüft.
- **Raspberry Pi (zurückgestellt).** `spec/deployment-targets/` stellt den Raspberry Pi zurück, daher lässt H7 aarch64 optional. Kehrt das Ziel zurück, wird aarch64 Pflicht, und das Update- und Rollback-Verhalten aus §B muss auch auf einem Board ohne UEFI-Firmware gelten. Welche Kandidaten das bieten, ist nicht geprüft; ein Kandidat, der es nicht kann, müsste dann ersetzt werden.
- **Artefaktformate.** `spec/deployment-targets/` §C verlangt ein Installer-ISO und ein vorinstalliertes Raw-Disk-Image. Weitere Formate folgen nur, wenn dort weitere Anbieter zu Zielen werden.
- **Erster Start ohne Registry.** C3 lässt den ersten Start die Images aus einer Registry laden, nach Entscheidung des Projektinhabers vom 2026-11-12. Wie sich die Appliance verhält, wenn die Registry in diesem Moment nicht erreichbar ist, etwa wie lange sie es erneut versucht und was der Nutzer sieht, ist nicht entschieden.
- **Überschreiben über Provisionierungsdaten.** D11 erfüllt der Prototyp mit einer Datei auf der Appliance. Dieselben Werte vor dem ersten Start über die Provisionierungsdaten aus D4 zu setzen, braucht cloud-init oder Gleichwertiges im Image, was der Prototyp noch nicht enthält.
- **Einen Wert ändern, der gleich bleiben muss.** D12 stoppt die Dienste, wenn sich ein solcher Wert ändert. Wie ein Nutzer das Datenbankpasswort, das die Datenbank seit ihrem Anlegen behält, bewusst ändert, ist heute eine manuelle Folge: zuerst in der Datenbank, dann in der Nutzerdatei, dann die Prüfung freigeben. Ob die Appliance das als einen Schritt anbieten soll, ist nicht entschieden.
- **Rollback nach einer Datenmigration.** B3 bringt das System auf die vorherige Version zurück, während E1 die Daten unberührt lässt. Hat das neuere Kamerplanter-Release die Datenbanken bereits migriert, läuft die vorherige Version darauf möglicherweise nicht. Die Distribution kann das nicht lösen; es braucht eine Entscheidung im Update-Spec.
- **Health-Check für B3.** Die Appliance muss deklarieren, was nach einem Update „healthy“ bedeutet. Diese Definition hängt von den Health-Endpunkten des Hauptprojekts ab und ist noch nicht geschrieben.
- **Ein Update oder zwei.** B9 bevorzugt ein Update für Betriebssystem und Container; B8 bevorzugt den Mechanismus der Distribution. Wo eine Distribution nur sich selbst aktualisiert und Container einer Registry überlässt, ziehen beide in verschiedene Richtungen: Ein Update braucht einen Build und eine Update-Quelle dieses Projekts, zwei Updates brauchen keines von beiden, erlauben aber Kombinationen, die nie gemeinsam veröffentlicht wurden. Was schwerer wiegt, ist nicht entschieden und wird mit der Wahl der Distribution geklärt.
- **Update-Quelle.** B10 bevorzugt eine vom Projekt kontrollierte Quelle; ob es eine gibt, wo sie gehostet wird und wie Releases signiert werden, ist nicht entschieden.
- **Welche Sicherheits-Baseline.** K2 und K5 verlangen eine Baseline und eine Prüfung dafür, aber nicht, welchem Standard sie folgt. Ein veröffentlichter Benchmark oder der Härtungsleitfaden der Distribution kommen in Frage; die Wahl hängt von der Distribution ab und ist nicht entschieden.
- **Schutz vor Brute-Force und Fluten.** G8 und G9 nennen fail2ban nur als Beispiel. Welches Werkzeug sie trägt, hängt von der Distribution ab, weil nicht jedes Immutable-System die Laufzeitumgebung mitbringt, die fail2ban braucht. Ebenfalls nicht entschieden ist, wo fehlgeschlagene Anmeldungen an der Kamerplanter-API für den Host sichtbar werden und welche Komponente TLS terminiert und die Ratenbegrenzung anwendet. Der Schutz deckt Angriffe aus wenigen Quellen ab; einen volumetrischen Angriff muss der Anbieter oder ein vorgeschalteter Dienst aufhalten.
