# Release-Verteilung

Status: draft

## Kontext

Ein Nutzer installiert die Appliance aus einer Datei, die er herunterlädt: einem Installer-ISO oder einem Disk-Image. Diese Datei wird zum Betriebssystem seines Servers, eine manipulierte Kopie würde also die ganze Maschine einem Angreifer übergeben. Dieses Spec legt fest, wie die Auslieferungsartefakte entstehen, wo sie veröffentlicht werden und wie ein Nutzer nachweisen kann, dass eine Datei diejenige ist, die dieses Projekt gebaut hat. Der Weg ist der, den die umliegenden Projekte bereits nutzen: Ein GitHub-Actions-Workflow baut die Artefakte und veröffentlicht sie als Assets eines GitHub-Releases.

Festgestellt am 2026-11-12. Dieses Repository enthält noch keinen Workflow: Sein Arbeitsverzeichnis enthält nur `README.md` und `spec/` (`git status`). Das Hauptprojekt `nolte/kamerplanter` veröffentlicht bereits über einen release-drafter-Entwurf und einen Workflow `release-publish.yml` und attestiert seine Container-Images mit `actions/attest-build-provenance` (`.github/workflows/` in einer Arbeitskopie). Dieses Repository erbt die Portfolio-Specs des Hubs `nolte/claude-shared` am Tag `v0.1.11` (`spec/.spec-config.yml`); dieses Release führt unter anderem `project/release-automation`, `project/release-artifact` und `project/branching-model` (`git grep` nach `Portfolio-Scope: portfolio` am Tag). Der Branch `develop` des Hubs führt zusätzlich `artifact-signing` und `continuous-delivery`; sie fehlen in `v0.1.11` und werden daher nicht geerbt. `artifact-signing` schreibt schlüsselloses Signieren für Container-Images und Helm-Charts vor und deckt herunterladbare Dateien wie ISOs und Disk-Images nicht ab. Aus der GitHub-Dokumentation: Jedes Release-Asset muss kleiner als 2 GiB sein, die Gesamtgröße ist nicht begrenzt [R1]; ein unveränderliches Release sperrt seine Assets und seinen Tag nach der Veröffentlichung und erzeugt eine Release-Attestierung [R2][R4][R5]; Artefakt-Attestierungen lassen sich für beliebige Dateien erzeugen und mit `gh attestation verify` prüfen [R3].

Nicht festgestellt: wie groß das ISO und das Raw-Disk-Image werden, was darüber entscheidet, ob sie unter die 2-GiB-Grenze passen; gebaut wurde nichts. Ob `gh attestation verify` ohne GitHub-Anmeldung funktioniert, wurde nicht nachgeschlagen. Die Dokumentationszitate stammen aus den abgerufenen Seiten und wurden nicht Byte für Byte mit den Originalen verglichen.

Abgrenzung: `spec/deployment-targets/` legt fest, welche Artefakte es gibt und wo sie installiert werden; `spec/distribution-requirements/` legt fest, was das Betriebssystem leistet, einschließlich der Echtheitsprüfung von Updates. Dieses Spec legt den Weg von einem Commit zu einem veröffentlichten, prüfbaren Artefakt fest. Formulierung der Release Notes, Umgang mit Versionen und das Branch-Modell gehören zu den geerbten Portfolio-Specs `project/release-automation` und `project/branching-model` und werden hier nicht neu definiert.

Leser: Maintainer, die die Workflows schreiben, Reviewer des Release-Prozesses und Autoren der Installationsdokumentation.

## Ziele

- Jedes Artefakt, das ein Nutzer herunterladen kann, wurde von der CI des Projekts aus einem bekannten Commit gebaut, und niemand kann es nachträglich ersetzen.
- Ein Nutzer kann mit einer kurzen, dokumentierten Prüfung nachweisen, dass eine heruntergeladene Datei echt ist, bevor er sie bootet.
- Es gibt kein langlebiges Signier-Geheimnis, das gestohlen werden könnte.
- Ein Release ist ein wiederholbarer Workflow-Lauf, kein manuelles Verfahren.

## Nicht-Ziele

- Schutz vor einer Kompromittierung von GitHub selbst oder der Signier-Infrastruktur.
- Verteilung über App-Stores, Marktplätze der Anbieter oder Paketquellen.
- Signieren für Secure Boot. Das betrifft die Boot-Kette im Image, nicht den Download.
- Prüfung in einem Admission-Controller eines Clusters, die das Portfolio-Spec zur Signierung für Container-Deployments abdeckt.
- Die Formulierung der Release Notes.

## Anforderungen

### A. Build in der CI

- **A1 MUSS [MUST]** jedes Auslieferungsartefakt in einem GitHub-Actions-Workflow dieses Repositorys bauen und nie auf einem Entwicklerrechner.
- **A2 MUSS [MUST]** auf von GitHub gehosteten Runnern bauen.
- **A3 MUSS [MUST]** alle Artefakte eines Releases in einem Workflow-Lauf aus einem Commit bauen.
- **A4 MUSS [MUST]** jede Build-Eingabe pinnen: das Basis-Image per Digest, die Container-Images per Digest und jede Action per Commit-SHA.
- **A5 SOLLTE [SHOULD]** denselben Build ohne Veröffentlichung bei jeder Änderung am Integrations-Branch ausführen, sodass ein Release nie der erste Build seines Inhalts ist.
- **A6 MUSS [MUST]** Workflows standardmäßig nur Leserechte geben und mehr nur dem Job gewähren, der es braucht.

### B. Release

- **B1 MUSS [MUST]** die Artefakte als Assets eines GitHub-Releases dieses Repositorys veröffentlichen.
- **B2 MUSS [MUST]** jedes Release als Entwurf vorbereiten, alle Artefakte und ihr Prüfmaterial an den Entwurf anhängen und es erst veröffentlichen, wenn es vollständig ist.
- **B3 MUSS [MUST]** über einen Release-Workflow veröffentlichen, der bewusst gestartet wird, und nie durch Hochladen von Dateien von Hand.
- **B4 MUSS [MUST]** die Unveränderlichkeit von Releases für das Repository aktivieren, sodass sich Assets und Tag nach der Veröffentlichung nicht ändern können.
- **B5 MUSS [MUST]** eine Version im Release-Tag, in jedem Dateinamen der Artefakte und in der System-Image-Kennung führen.
- **B6 DARF NICHT [MUST NOT]** ein veröffentlichtes Artefakt ersetzen; ein Fehler wird durch eine neue Version korrigiert.
- **B7 MUSS [MUST]** ein Release erst veröffentlichen, nachdem die Verifikation, die `spec/deployment-targets/` §G verlangt, dafür bestanden ist.
- **B8 MUSS [MUST]** das Release scheitern lassen, statt es zu veröffentlichen, wenn ein Artefakt die Größengrenze eines Release-Assets überschreitet.
- **B9 MUSS [MUST]** in den Release Notes die Kamerplanter-Version, die Version der Basis-Distribution und die geprüften Ziele nennen.

### C. Veröffentlichte Menge

- **C1 MUSS [MUST]** mit jedem Release das Installer-ISO, das Raw-Disk-Image, eine Prüfsummendatei, das Prüfmaterial und die Komponentenlisten veröffentlichen.
- **C2 MUSS [MUST]** eine Prüfsummendatei veröffentlichen, die den SHA-256-Digest jedes Artefakts des Releases aufführt.
- **C3 MUSS [MUST]** für jedes Artefakt eine Komponentenliste veröffentlichen, wie `spec/distribution-requirements/` §F es verlangt.
- **C4 MUSS [MUST]** das System-Image unter derselben Version in der Container-Registry des Projekts veröffentlichen und per Digest referenzieren, wo das System als Container-Image ausgeliefert oder aktualisiert wird.
- **C5 KANN [MAY]** Artefakte komprimieren, sofern der dokumentierte Installationsweg das Format nennt.

### D. Signierung

- **D1 MUSS [MUST]** jedes veröffentlichte Artefakt und die Prüfsummendatei signieren.
- **D2 MUSS [MUST]** schlüssellos mit der Identität des Release-Workflows signieren, bezogen über das OIDC-Token von GitHub Actions.
- **D3 DARF NICHT [MUST NOT]** einen langlebigen privaten Signierschlüssel im Repository, in dessen Secrets oder auf einem Runner ablegen.
- **D4 MUSS [MUST]** für jedes Artefakt eine Build-Provenance-Attestierung erzeugen, die es an dieses Repository, den Workflow und den Commit bindet.
- **D5 MUSS [MUST]** die Berechtigungen zum Signieren und Attestieren nur dem Job gewähren, der signiert.
- **D6 MUSS [MUST]** nur signieren, was derselbe Workflow-Lauf gebaut hat.
- **D7 MUSS [MUST]** das Signaturmaterial als Release-Assets neben den Artefakten veröffentlichen.
- **D8 MUSS [MUST]** das System-Image in der Container-Registry mit derselben Identität signieren, sodass es sich wie die heruntergeladenen Artefakte prüfen lässt. Solange die Container-Werkzeuge auf der Appliance diese Identität nicht prüfen können, **MUSS [MUST]** das System-Image zusätzlich eine Signatur mit einem Update-Schlüssel tragen, dessen öffentlicher Teil im Image liegt, und die Update-Prüfung aus `spec/distribution-requirements/` §B nutzt diesen Schlüssel.

### E. Prüfung durch den Nutzer

- **E1 MUSS [MUST]** die Prüfung in der README und in den Notes jedes Releases dokumentieren, mit den genauen Kommandos.
- **E2 MUSS [MUST]** die Prüfung eines heruntergeladenen Artefakts zu einem einzigen Kommando machen.
- **E3 MUSS [MUST]** den erwarteten Unterzeichner veröffentlichen: Repository, Workflow und Token-Aussteller; die dokumentierten Kommandos pinnen alle drei.
- **E4 MUSS [MUST]** die Prüfung für eine Datei scheitern lassen, die der Release-Workflow dieses Repositorys nicht gebaut hat, einschließlich einer in einem Fork neu gebauten Kopie.
- **E5 SOLLTE [SHOULD]** die Prüfung ohne GitHub-Konto erlauben.
- **E6 SOLLTE [SHOULD]** die Prüfung ohne Netzwerkzugang erlauben, sobald das Prüfmaterial heruntergeladen ist.
- **E7 MUSS [MUST]** den Prüfschritt in jeden dokumentierten Installationsweg aufnehmen, bevor das Artefakt geschrieben oder gebootet wird.
- **E8 MUSS [MUST]** eine installierte Appliance ihre Version und System-Image-Kennung anzeigen lassen, sodass der Nutzer sie mit dem Release vergleichen kann.

### F. Integrität des Release-Wegs

- **F1 MUSS [MUST]** einschränken, wer den Release-Workflow starten und wer Release-Tags anlegen kann.
- **F2 DARF NICHT [MUST NOT]** einen Job mit Signier-Berechtigungen auf Code aus einem Pull Request oder einem Fork ausführen.
- **F3 MUSS [MUST]** dokumentieren, wie ein fehlerhaftes oder kompromittiertes Release behandelt wird: als zurückgezogen kennzeichnen, eine korrigierte Version veröffentlichen und den Nutzern mitteilen, welche Versionen betroffen sind.
- **F4 SOLLTE [SHOULD]** das öffentliche Transparenz-Log auf Signaturen mit der Identität des Projekts beobachten, die zu keinem Release-Lauf gehören.

## Akzeptanzkriterien

Die Kriterien fassen mehrere Anforderungen zusammen; jede Anforderung bleibt für sich normativ.

- [ ] Ein Release entsteht durch einen Workflow-Lauf auf von GitHub gehosteten Runnern, und jedes seiner Artefakte nennt in seiner Provenance denselben Commit (A1, A2, A3, D4).
- [ ] Die Workflow-Dateien referenzieren jede Action per Commit-SHA und jedes Image per Digest, und kein Workflow gewährt Schreibrechte auf Workflow-Ebene (A4, A6).
- [ ] Das Release enthält das Installer-ISO, das Raw-Disk-Image, eine Prüfsummendatei über alle Artefakte, Signaturmaterial für jedes und eine Komponentenliste für jedes (C1, C2, C3, D1, D7).
- [ ] Tag, Dateinamen der Artefakte und die System-Image-Kennung einer aus dem Release installierten Appliance tragen dieselbe Version (B5, E8).
- [ ] Ein Versuch, ein Asset eines veröffentlichten Releases zu ersetzen oder zu löschen oder dessen Tag zu verschieben, wird von der Plattform abgelehnt (B4, B6).
- [ ] Das Release war ein Entwurf, bis alle Assets angehängt waren, und der Lauf, der es veröffentlicht hat, hat auch die bestandene Zielverifikation festgehalten (B2, B3, B7).
- [ ] Ein Build mit einem Artefakt über der Größengrenze für Assets endet ohne veröffentlichtes Release (B8).
- [ ] Das Repository und seine Einstellungen enthalten keinen privaten Signierschlüssel, und nur der Signier-Job hält die Berechtigungen zum Signieren und Attestieren (D2, D3, D5, D6).
- [ ] Das dokumentierte Kommando prüft ein heruntergeladenes Artefakt des Releases erfolgreich (E1, E2, E3).
- [ ] Dasselbe Kommando scheitert für eine Datei mit einem geänderten Byte und für ein Artefakt, das derselbe Workflow in einem Fork gebaut hat (E4).
- [ ] Die Prüfung gelingt auf einer Maschine ohne GitHub-Anmeldung und, mit vorliegendem Prüfmaterial, ohne Netzwerkzugang; wo eines davon nicht möglich ist, sagt die Dokumentation das (E5, E6).
- [ ] Jede Installationsanleitung für ein Ziel setzt die Prüfung vor den Schritt, der das Artefakt schreibt oder bootet (E7).
- [ ] Das System-Image in der Registry lässt sich gegen denselben Unterzeichner prüfen wie die heruntergeladenen Artefakte und gegen den Update-Schlüssel, dem eine installierte Appliance vertraut (C4, D8).
- [ ] Ein Pull Request aus einem Fork kann keinen Job mit Signier-Berechtigungen starten, und nur benannte Rollen können den Release-Workflow starten oder einen Release-Tag anlegen (F1, F2).
- [ ] Die Release Notes nennen die Kamerplanter-Version, die Version der Basis-Distribution und die geprüften Ziele, und das Verfahren für ein zurückgezogenes Release ist dokumentiert (B9, F3).

## Referenzen

- Quellen abgerufen am 2026-11-12.
- [R1] GitHub Docs, „About releases“ (P): <https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases>
- [R2] GitHub Docs, „Immutable releases“ (P): <https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/immutable-releases>
- [R3] GitHub Docs, „Using artifact attestations to establish provenance for builds“ (P): <https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds>
- [R4] GitHub Docs, „Verifying the integrity of a release“ (P): <https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity>
- [R5] GitHub Docs, „Preventing changes to your releases“ (P): <https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes>

## Offene Fragen

- **Artefakte über 2 GiB.** B8 stoppt ein Release, dessen Artefakt die Grenze eines Release-Assets überschreitet [R1], sagt aber nicht, was dann geschieht. Gebaut wurde nichts, die Größen sind also unbekannt. Stärkere Kompression, Aufteilen in Teile oder ein zweiter Download-Ort sind die Möglichkeiten, und jede verändert die Prüfung, die der Nutzer durchführen muss.
- **Welches Prüfwerkzeug.** Entschieden: Der Release-Workflow hängt je Artefakt ein cosign-Signatur-Bundle an, prüfbar ohne GitHub-Konto, und hält eine Herkunftsbescheinigung fest, prüfbar mit `gh attestation verify` (`docs/de/references/verify.md`). Ob `gh attestation verify` ohne GitHub-Anmeldung funktioniert, ist weiterhin nicht nachgeschlagen.
- **Signier-Specs außerhalb des gepinnten Hub-Releases.** `artifact-signing` und `continuous-delivery` gibt es nur auf dem Branch `develop` des Hubs. Sobald ein Hub-Release sie enthält und der Pin in `spec/.spec-config.yml` angehoben wird, müssen die Regeln hier damit abgeglichen werden. Ein Punkt ist schon sichtbar: `artifact-signing` beschränkt Signier-Jobs auf Push-Events für Release-Refs, während B2 und B3 hier den Release-Workflow signierte Artefakte vor der Veröffentlichung an einen Entwurf anhängen lassen.
- **Signieren von Dateien im Hub.** Das noch nicht veröffentlichte Spec `artifact-signing` des Hubs deckt nur Container-Images und Helm-Charts ab. Ob die hier geschriebenen Regeln für herunterladbare Dateien dorthin wandern sollen, ist eine Frage für den Hub, nicht für dieses Repository.
- **Branch-Einrichtung.** Das geerbte `project/branching-model` macht `develop` zum Integrations-Branch und `main` zum Branch, der das zuletzt veröffentlichte Release zeigt. Dieses Repository hat nur `main`, ohne Commits; die Branches und ihr Schutz müssen eingerichtet werden, bevor A5 und B3 erfüllbar sind.
- **Attestierungen in diesem Repository.** Die Dokumentationsseite sagt nicht, für welche Tarife und Sichtbarkeiten von Repositorys Artefakt-Attestierungen verfügbar sind [R3]. Das muss für dieses Repository bestätigt werden, bevor man sich auf D4 verlassen kann.
