# Update und Rollback

Status: draft

## Kontext

Auch eine Appliance, die der Nutzer nie administriert, muss sich ändern: Kamerplanter veröffentlicht neue Versionen, die Basis-Distribution liefert Sicherheitskorrekturen, und die Appliance selbst entwickelt sich weiter. Dieses Spec legt fest, wie eine solche Änderung eine installierte Appliance erreicht, was der Self-Hoster dabei erlebt, wie ein gescheitertes Update rückgängig gemacht wird und was der Self-Hoster steuern kann oder wissen muss. Angestrebt ist, dass Updates weder eine Handlung noch Aufmerksamkeit brauchen und dass ein gescheitertes Update die Appliance so hinterlässt, wie sie war, einschließlich der Daten.

`AUDIENCES.md` nennt den Self-Hoster als primäre Zielgruppe. Infrastructure-as-Code-Automatisierung, die Appliances anlegt und ersetzt, ist eine sekundäre Zielgruppe dieses Specs.

Festgestellt am 2026-11-13:

- Eine aus dem jetzigen Proof of Concept installierte Appliance kann sich überhaupt nicht aktualisieren. `bootc status` meldet in Boot-Lauf 1 die Image-Referenz `localhost/kamerplanter-appliance:poc` als Update-Quelle (`.build/boot/run1.measure.txt`), eine Referenz, die keine Registry ausliefert.
- Das Basissystem aktualisiert sich über bootc: `bootc upgrade` legt ein neues System-Image neben dem laufenden bereit und wechselt beim nächsten Boot; das vorherige Deployment bleibt bootbar; `/var` existiert einmal und wird von Update und Rollback nicht berührt, während `/etc` je Deployment zusammengeführt wird [R1][R2]. Der Standard-Timer `bootc-fetch-apply-updates.timer` lädt und aktiviert mit sofortigem Neustart, und seine Dokumentation erwartet, dass der Zeitplan überschrieben wird [R3][R4]. bootc selbst rollt nur ein Deployment zurück, das nicht bootet; ein Rollback nach gescheiterter Gesundheitsprüfung braucht greenboot, das im Image noch fehlt [R2][R5].
- Das Kamerplanter-Backend wendet bei jedem Start Datenbankmigrationen unter einer Sperre an, die nach 300 Sekunden verfällt (`src/backend/app/migrations/framework/runner.py`, `tracking.py` in `nolte/kamerplanter`). Von den 108 Migrationen in dieser Arbeitskopie erklären sich 2 als umkehrbar; die Migrationsvorlage setzt standardmäßig `reversible = False` (`src/backend/app/migrations/framework/cli.py`). Eine ältere Kamerplanter-Version kann daher im Allgemeinen nicht auf Daten laufen, die eine neuere Version migriert hat.
- Die Container-Images sind im System-Image per Digest gepinnt (`image/rootfs/usr/share/containers/systemd/`), sodass eine System-Image-Version immer die Kamerplanter-Version startet, mit der sie veröffentlicht wurde.

Für den Prototyp der Stufe 2 am 2026-11-13 entschieden, nach den Befunden in `spec/distribution-requirements/` (offene Fragen zu B3 und B6):

- Die Appliance prüft Updates gegen einen Update-Schlüssel, der im Image liegt, weil die Policy-Prüfung, die bootc anwendet, die schlüssellose Identität des Release-Workflows nicht prüfen kann (`spec/release-distribution/` D8).
- `kamerplanter-update` (`image/rootfs/usr/bin/`) setzt Suche, Aktivierung im Fenster, die Datensicherung als Kopie der Datenbank-Volumes, die Gesundheitsprüfung und den Rollback mit `bootc rollback` um; greenboot wird nicht genutzt, weil sein Boot-Zähler die GRUB-Konfiguration nicht erreicht, die bootc installiert.
- Die Kamerplanter-Container-Images sind logisch gebundene Images, die bei der Installation in die Disk geholt und mit jedem Update bereitgelegt werden.

Nicht festgestellt: ob bootcs logisch gebundene Images mit den Quadlet-Units der Appliance und dem Weg über den Anaconda-Installer funktionieren und wie lange ein Update auf den Referenzzielen dauert. Beides zu klären braucht den Prototyp der Stufe 2, der geplant, aber nicht gebaut ist.

Abgrenzung: `spec/distribution-requirements/` §B legt fest, welche Fähigkeiten die Basis-Distribution bieten muss (Atomarität, Erhalt der vorherigen Version, Echtheitsprüfung); dieses Spec legt den darauf aufbauenden Ablauf fest und was der Self-Hoster erlebt. `spec/release-distribution/` legt fest, wie Releases gebaut, signiert und veröffentlicht werden; dieses Spec beginnt dort, wo ein veröffentlichtes Release existiert. Die Migrationsregeln von Kamerplanter selbst gehören zu `nolte/kamerplanter`.

Leser: der Maintainer, der Updates umsetzt und veröffentlicht, und die Autoren der Dokumentation für Self-Hoster.

## Ziele

- Eine installierte Appliance bleibt ohne Zutun des Self-Hosters aktuell.
- Ein Update hinterlässt die Appliance nie in einem schlechteren Zustand als vorher: Entweder wird es abgeschlossen und besteht seine Gesundheitsprüfung, oder die Appliance kehrt zur vorherigen Version mit den vorherigen Daten zurück.
- Der Self-Hoster kann sehen, welche Version läuft, was als Nächstes kommt und was beim letzten Update geschah, und kann wählen, wann Updates aktiv werden.
- Für den Wechsel auf eine neuere Version ist nie eine Neuinstallation nötig, auch nicht bei einer neuen Hauptversion der Basis-Distribution.

## Nicht-Ziele

- Kamerplanter-Container unabhängig vom System-Image aktualisieren.
- Mehrere Update-Kanäle mit unterschiedlicher Stabilität; ein stabiler Kanal genügt vorerst.
- Updates, die ein zentraler Verwaltungsdienst oder Flotten-Controller anstößt.
- Sicherung der Daten der Appliance für die Wiederherstellung nach einem Ausfall; dieses Spec deckt nur den Datenschutz ab, den ein Update braucht.
- Downgrade auf eine beliebige ältere Version.

## Anforderungen

### A. Versionen und Quellen

- **A1 MUSS [MUST]** jedes Update als vollständiges, veröffentlichtes Appliance-Release ausliefern, das eine System-Image-Version, einen Satz Kamerplanter-Container-Images und eine Version der Basis-Distribution trägt.
- **A2 MUSS [MUST]** jede Appliance mit der Registry-Referenz ihres Release-Kanals als Update-Quelle installieren, nie mit einer lokalen oder zur Build-Zeit gültigen Referenz.
- **A3 MUSS [MUST]** Appliances nur Releases anbieten, die über `spec/release-distribution/` veröffentlicht wurden; Entwürfe und Builds aus Pull Requests erreichen nie eine installierte Appliance.
- **A4 MUSS [MUST]** ein Update nur vorwärts gehen lassen; ein Release, das älter ist als das laufende, wird nie angeboten.
- **A5 MUSS [MUST]** eine Appliance von jedem unterstützten Release direkt auf das neueste aktualisieren lassen, ohne Zwischen-Releases, die der Self-Hoster der Reihe nach installieren muss.
- **A6 MUSS [MUST]** für jedes Release dokumentieren, ob sein Update Daten so ändert, dass ein Rollback es ohne Wiederherstellen einer Sicherung nicht rückgängig machen kann.

### B. Erkennen und Herunterladen

- **B1 MUSS [MUST]** selbstständig mindestens einmal am Tag nach einem neuen Release suchen.
- **B2 MUSS [MUST]** nur ausgehende Verbindungen nutzen, sodass eine Appliance hinter NAT und ohne Portweiterleitung Updates erhält.
- **B3 MUSS [MUST]** die Signatur eines neuen System-Images gegen die Identität des Release-Workflows prüfen, bevor sie es bereitlegt, und ein Image verwerfen, das die Prüfung nicht besteht.
- **B4 MUSS [MUST]** das neue System-Image und die Container-Images, auf die es verweist, vor dem aktivierenden Neustart vollständig bereitlegen, sodass der erste Boot der neuen Version keinen Registry-Zugriff braucht.
- **B5 MUSS [MUST]** die Dienste unverändert weiterlaufen lassen, während ein Update heruntergeladen und bereitgelegt wird.
- **B6 MUSS [MUST]** eine gescheiterte Suche oder einen gescheiterten Download später selbstständig wiederholen, ohne Handlung des Nutzers und ohne die laufenden Dienste zu blockieren.
- **B7 MUSS [MUST]** eine Appliance ohne Internetzugang unbegrenzt auf ihrer aktuellen Version weiterlaufen lassen und sie aktualisieren, sobald der Zugang zurückkehrt.
- **B8 SOLLTE [SHOULD]** nur die geänderten Teile des System-Images herunterladen.

### C. Aktivierung

- **C1 MUSS [MUST]** ein bereitgelegtes Update nur innerhalb eines Wartungsfensters aktivieren.
- **C2 MUSS [MUST]** ein Standard-Wartungsfenster mitbringen, das in die Nacht der eingestellten Zeitzone der Appliance fällt.
- **C3 MUSS [MUST]** den Self-Hoster das Wartungsfenster in der Konfigurationsdatei des Nutzers festlegen lassen.
- **C4 MUSS [MUST]** ein Update mit genau einem Neustart aktivieren.
- **C5 MUSS [MUST]** die zu erwartende Unterbrechung von Web-UI und API während der Aktivierung dokumentieren.
- **C6 SOLLTE [SHOULD]** den Self-Hoster ein bereitgelegtes Update mit einem dokumentierten Kommando sofort aktivieren lassen.
- **C7 SOLLTE [SHOULD]** den Self-Hoster Updates für eine begrenzte Zeit aufschieben lassen, nach der sie selbstständig wieder einsetzen.
- **C8 DARF [MAY]** den Self-Hoster eine bestimmte Version festhalten lassen.

### D. Daten während eines Updates

- **D1 MUSS [MUST]** alle persistenten Daten, die Konfiguration des Nutzers und die erzeugten Geheimnisse über ein Update und über einen Rollback hinweg erhalten.
- **D2 MUSS [MUST]** vor dem ersten Start einer neuen Version eine konsistente Sicherung jeder Datenbank anlegen, die die neue Version migrieren kann, aufgenommen bei angehaltenen Diensten.
- **D3 MUSS [MUST]** diese Sicherung wiederherstellen, wenn die Appliance von einer Version zurückrollt, die bereits gegen die Daten gestartet ist; ein Rollback lässt die vorherige Version nie auf Daten laufen, die die neuere migriert hat.
- **D4 MUSS [MUST]** die Sicherung aus D2 behalten, bis die neue Version ihre Gesundheitsprüfung bestanden hat und einen festgelegten Zeitraum ohne Rollback gelaufen ist, und sie danach löschen.
- **D5 MUSS [MUST]** die Aktivierung eines Updates verweigern, wenn am Speicherort der Daten der Platz für die Sicherung aus D2 fehlt, und den Grund melden.
- **D6 MUSS [MUST]** dem Self-Hoster in der Dokumentation und im Protokoll des Rollbacks aus D3 mitteilen, dass Daten, die zwischen Update und Rollback geschrieben wurden, mit der Wiederherstellung verloren gehen.
- **D7 MUSS [MUST]** jedes Geheimnis erzeugen, das eine neue Version zusätzlich braucht, und jedes vorhandene behalten, wie `spec/distribution-requirements/` D9 und D10 verlangen.

### E. Gesundheitsprüfung und automatischer Rollback

- **E1 MUSS [MUST]** die Gesundheit einer neuen Version so festlegen: Die Konfigurationsprüfung besteht, alle Core-Container melden sich gesund, und Web-UI und API antworten, alles innerhalb eines angegebenen Zeitbudgets nach dem aktivierenden Boot.
- **E2 MUSS [MUST]** selbstständig zur vorherigen Version zurückrollen, wenn die neue Version nicht bootet oder E1 nicht besteht.
- **E3 MUSS [MUST]** die Zahl automatischer Rollback-Versuche begrenzen, sodass ein Fehler nie in einer Neustartschleife endet.
- **E4 DARF NICHT [MUST NOT]** eine Version erneut versuchen, die gescheitert ist und zurückgerollt wurde; die Appliance wartet auf ein neueres Release.
- **E5 MUSS [MUST]** für jeden Update-Versuch Version, Zeitpunkt, Ergebnis und bei einem Rollback die gescheiterte Prüfung festhalten, nachträglich für den Self-Hoster lesbar.
- **E6 MUSS [MUST]** einen ersten Start, der berechtigt lange dauert, etwa durch Datenmigrationen, innerhalb seines Zeitbudgets als gesund behandeln und nicht vorzeitig zurückrollen.

### F. Manueller Rollback

- **F1 MUSS [MUST]** den Self-Hoster mit einem dokumentierten Kommando zur vorherigen Version zurückkehren lassen.
- **F2 MUSS [MUST]** D2 bis D6 auf einen manuellen Rollback genauso anwenden wie auf einen automatischen.
- **F3 MUSS [MUST]** angeben, dass für einen Rollback nur die vorherige Version zur Verfügung steht.
- **F4 MUSS [MUST]** verhindern, dass eine manuell zurückgerollte Appliance erneut auf dasselbe gescheiterte Release aktualisiert wird, wie E4 es für automatische Rollbacks verlangt.

### G. Sichtbarkeit

- **G1 MUSS [MUST]** nach dem Boot auf der Konsole die laufende Version, eine gegebenenfalls bereitgelegte Version und den Zeitpunkt des nächsten Wartungsfensters anzeigen.
- **G2 MUSS [MUST]** dieselben Angaben und das Protokoll aus E5 über ein dokumentiertes Kommando und in maschinenlesbarer Form bereitstellen.
- **G3 MUSS [MUST]** zu jedem Release Release Notes veröffentlichen, die die Kamerplanter-Version, die Version der Basis-Distribution, Konfigurationsänderungen und die Frage nennen, ob ein Rollback eine Wiederherstellung der Daten braucht (A6).
- **G4 SOLLTE [SHOULD]** den Self-Hoster ohne Anmeldung von einem gescheiterten Update oder einem Rollback erfahren lassen, zum Beispiel über die Web-UI oder eine Benachrichtigung.

### H. Sicherheitskorrekturen und Unterstützung

- **H1 MUSS [MUST]** ein Release, das eine Sicherheitskorrektur für die Basis-Distribution, die Container-Laufzeit oder einen mitgelieferten Container enthält, innerhalb einer angegebenen Zeit nach Verfügbarkeit der Korrektur veröffentlichen.
- **H2 MUSS [MUST]** ein Release, das nur Sicherheitskorrekturen trägt, denselben Weg nehmen lassen wie jedes andere Release.
- **H3 MUSS [MUST]** angeben, wie lange ein Release der Appliance Updates erhält und was geschieht, wenn seine Unterstützung endet.
- **H4 MUSS [MUST]** eine Appliance, deren Release nicht mehr unterstützt wird, weiterlaufen lassen und diesen Zustand wie in G1 anzeigen.

### I. Dokumentation für den Self-Hoster

- **I1 MUSS [MUST]** eine Seite bereitstellen, die Updates und Rollbacks aus Sicht des Self-Hosters erklärt: was wann geschieht, was sich einstellen lässt, was schiefgehen kann und was dann zu tun ist.
- **I2 MUSS [MUST]** beschreiben, wie man das Update-Protokoll (E5) liest und wie man manuell zurückrollt (F1).
- **I3 MUSS [MUST]** erklären, dass eine Appliance, die aus einem Release vor Erfüllung von A2 installiert wurde, sich nicht aktualisiert, und wie man sie auf eine sich aktualisierende umstellt.

## Akzeptanzkriterien

Die Kriterien fassen mehrere Anforderungen zusammen; jede Anforderung bleibt für sich normativ. Geprüft werden sie durch Boot-Läufe des Prototyps der Stufe 2.

- [ ] Eine frisch installierte Appliance meldet die Registry-Referenz des Release-Kanals als Update-Quelle (A2).
- [ ] Eine aus Release N installierte Appliance aktualisiert sich ohne Zutun innerhalb eines Tages plus eines Wartungsfensters auf das danach veröffentlichte Release N+1 und läuft danach gesund mit N+1 (A1, B1, C1, C4).
- [ ] Eine aus Release N installierte Appliance aktualisiert sich auf N+2, ohne N+1 zu installieren (A5).
- [ ] Ein Update mit einem Image, das von einer anderen Identität signiert wurde, wird verworfen, und die Appliance läuft mit ihrer Version weiter (B3).
- [ ] Während der Bereitstellung antworten Web-UI und API weiter; der erste Boot der neuen Version gelingt bei gesperrtem Registry-Zugriff (B4, B5).
- [ ] Eine Appliance, die eine Woche ohne Internetzugang ist, läuft weiter und aktualisiert sich innerhalb eines Tages, nachdem der Zugang zurückgekehrt ist (B6, B7).
- [ ] Ein geändertes Wartungsfenster in der Konfigurationsdatei des Nutzers verschiebt den aktivierenden Neustart in dieses Fenster (C1, C3).
- [ ] Ein Update auf ein Release, dessen Backend die Gesundheitsprüfung nicht besteht, endet auf dem vorherigen Release mit den Daten wie vor dem Update, und das Protokoll nennt die gescheiterte Prüfung (D2, D3, E1, E2, E5).
- [ ] Ein Update auf ein Release, das die Datenbank migriert und danach die Gesundheitsprüfung nicht besteht, endet auf dem vorherigen Release mit wiederhergestellter Sicherung, und das vorherige Release läuft gesund (D3).
- [ ] Ein Release, das nie gesund wird, verursacht höchstens die angegebene Zahl von Rollback-Versuchen und wird nicht erneut versucht (E3, E4).
- [ ] Ein Update, dessen erster Start wegen Migrationen länger als üblich, aber innerhalb seines Zeitbudgets dauert, wird nicht zurückgerollt (E6).
- [ ] Bei zu wenig freiem Platz für die Sicherung wird das Update nicht aktiviert, und der Grund wird festgehalten (D5).
- [ ] Ein manueller Rollback mit dem dokumentierten Kommando stellt das vorherige Release und seine Daten wieder her, und das gescheiterte Release wird nicht erneut versucht (F1, F2, F4).
- [ ] Die Konsole zeigt laufende Version, bereitgelegte Version und nächstes Fenster; das dokumentierte Kommando liefert dasselbe in maschinenlesbarer Form (G1, G2).
- [ ] Die Release Notes jedes Releases nennen Kamerplanter-Version, Basis-Version, Konfigurationsänderungen und ob ein Rollback eine Wiederherstellung braucht (A6, G3).
- [ ] Die Dokumentationsseite behandelt Updates, das Wartungsfenster, das Update-Protokoll, den manuellen Rollback, den Datenverlust bei der Wiederherstellung und die Umstellung einer Appliance, die sich nicht aktualisiert (D6, I1, I2, I3).

## Referenzen

- Quellen abgerufen am 2026-11-12 bei der Sichtung der Distributionen, die in `spec/distribution-requirements/` festgehalten ist.
- [R1] bootc-Dokumentation, „bootc-upgrades(7)“ (P): <https://github.com/bootc-dev/bootc/blob/main/docs/src/bootc-upgrades.7.md>
- [R2] bootc-Dokumentation, „bootc-boot-failure-detection(7)“ (P): <https://github.com/bootc-dev/bootc/blob/main/docs/src/bootc-boot-failure-detection.7.md>
- [R3] bootc-Dokumentation, „bootc-fetch-apply-updates.service(5)“ (P): <https://github.com/bootc-dev/bootc/blob/main/docs/src/man/bootc-fetch-apply-updates.service.5.md>
- [R4] Fedora-bootc-Dokumentation, „Auto-updates“ (P): <https://docs.fedoraproject.org/en-US/bootc/auto-updates/>
- [R5] greenboot-rs README (P): <https://github.com/fedora-iot/greenboot-rs/blob/main/README.md>
- [R6] bootc-Dokumentation, „bootc-logically-bound-images(7)“ (P): <https://github.com/bootc-dev/bootc/blob/main/docs/src/bootc-logically-bound-images.7.md>

## Offene Fragen

- **Verfahren der Datensicherung.** Der Prototyp kopiert die Datenbank-Volumes bei angehaltenen Datenbanken. Auf ext4 braucht das so viel freien Platz wie die Daten und dauert so lange wie die Kopie; bei großen Datenmengen ist ein Dateisystem-Snapshot oder ein Datenbank-Dump womöglich besser. Weder die Datenmenge auf echten Appliances noch die Dauer der Kopie wurde gemessen.
- **Eine Version, die den Userspace nicht erreicht.** E2 deckt auch eine Version ab, die nicht bootet. Die Prüfung des Prototyps läuft im Userspace, und ohne Boot-Zähler in der GRUB-Konfiguration kehrt nichts von einem hängenden Kernel zurück. In Frage kommen das GRUB-Snippet von greenboot-rs in der statischen Konfiguration von bootupd oder ein eigener Boot-Zähler von bootc.
- **Wann die vorherige Version als entbehrlich gilt.** D4 behält die Sicherung nach einem erfolgreichen Update für „einen festgelegten Zeitraum“. Ein Tag, eine Woche oder bis zum nächsten Update sind alle denkbar; abzuwägen ist Plattenplatz gegen die Möglichkeit, einen späten Fehler zu bemerken.
- **Vorab-Laden der Container-Images.** B4 braucht die neuen Kamerplanter-Images vor dem Neustart im lokalen Speicher. bootcs logisch gebundene Images leisten das [R6], ihre Unterstützung im Installer-Weg ist laut der Distributionssichtung aber eingeschränkt; ob sie mit den Units der Appliance funktionieren, ist nicht festgestellt.
- **Standard-Wartungsfenster und Zeitzone.** C2 legt das Standardfenster in die Nacht der Zeitzone der Appliance, aber die Appliance hat noch keinen Einrichtungsschritt, der nach einer Zeitzone fragt.
- **Wie der Self-Hoster von einem gescheiterten Update erfährt.** G4 verlangt einen Weg ohne Anmeldung. Die Web-UI gehört zu Kamerplanter, eine Meldung dort braucht also Unterstützung im Hauptprojekt; eine Benachrichtigung braucht einen eingerichteten Kanal. Beides ist offen.
- **Unterstützungszeitraum und Reaktionszeit bei Sicherheitslücken.** H1 und H3 brauchen konkrete Zahlen. Sie hängen von der Kapazität des Maintainers und vom Rhythmus der Basis-Distribution ab; solange die Basis Fedora Rawhide ist, ist kein stabiles Versprechen möglich.
- **Name des Release-Kanals und der Umstieg vom Proof of Concept.** A2 braucht eine Kanal-Referenz wie `ghcr.io/nolte/kamerplanter-appliance:stable`; ihr Name und ob Appliances den Kanal wechseln dürfen, sind offen. Aus Proof-of-Concept-Builds installierte Appliances brauchen einen dokumentierten einmaligen Wechsel (I3).
