# Einsatzziele

Status: draft

## Kontext

Die Kamerplanter-Appliance soll überall dort laufen, wo eine einzelne Person oder eine kleine Gruppe Kamerplanter betreiben will: auf einem gemieteten Server bei einem Hosting-Anbieter wie Hetzner oder OVH, auf einem privaten Virtualisierungshost mit Proxmox VE oder auf kleiner privater Hardware wie einem Mini-PC nach Art des Intel NUC. Der Raspberry Pi gehörte zur ursprünglichen Absicht und ist zurückgestellt: Er ist vorerst nicht im Umfang und unter den offenen Fragen für später vermerkt. Der Nutzer soll möglichst frei wählen können, wo die Appliance läuft, denn ihr Wert liegt nicht im Ort: Er liegt darin, den Betriebsaufwand eines Servers abzunehmen, etwa Patchen, Benutzerverwaltung und Sicherheits-Baselining, und das muss überall gelten, wo sie läuft. Dieses Spec legt fest, in welchen Umgebungen die Appliance installierbar sein muss und was jede davon verlangt, damit Build, Distributionswahl und Dokumentation auf dieselbe Menge von Zielen ausgerichtet sind.

Die Ziele stammen aus der Absichtserklärung des Projektinhabers. Festgestellt mit `docker buildx imagetools inspect` am 2026-11-12: `ghcr.io/nolte/kamerplanter-backend:0.4.2` und `ghcr.io/nolte/kamerplanter-frontend:0.4.2` sind nur für `linux/amd64` veröffentlicht, `arangodb:3.12` und `valkey/valkey:9-alpine` dagegen für `linux/amd64` und `linux/arm64`.

Festgestellt am 2026-11-12 durch Lesen der anbietereigenen Dokumentation über Recherche-Agenten: Kein untersuchter Anbieter lässt einen Kunden ein selbst gebautes Installer-ISO per Self-Service booten. Die Hetzner Cloud verlangt eine Support-Anfrage mit Download-Link und eine manuelle Netzwerkkonfiguration im Installer [R1][R2]; die Importwege der anderen nehmen nur Disk-Images an. Jeder untersuchte Anbieter hat einen Self-Service-Weg für ein vorinstalliertes Disk-Image:

| Anbieter | Self-Service-Weg für ein vorinstalliertes Disk-Image | Kann ein Hersteller das Image vorab veröffentlichen? |
|----------|------------------------------------------------------|------------------------------------------------------|
| Hetzner Cloud | Rescue-System booten, ein Raw-Image auf die Platte schreiben, Snapshot ziehen, Server daraus erstellen. Die API hat keinen Image-Upload [R3]. Hetzners Packer-Plugin und ein Community-Werkzeug automatisieren die Schritte [R5][R6]. | Nein. Snapshots lassen sich in ein anderes Projekt verschieben, aber nicht teilen oder veröffentlichen [R3][R4]. |
| OVHcloud Public Cloud | Ein Raw- oder qcow2-Image über die OpenStack-CLI oder Horizon hochladen [R7]. | Nur an benannte Projekte, je Region, mit Annahme durch den Empfänger [R8]. |
| OVHcloud dedizierte Server | „Bring Your Own Image“: OVH lädt ein Raw- oder qcow2-Image von einer URL und schreibt es auf die erste Platte [R9]. | Eine veröffentlichte Image-URL genügt. |
| OVHcloud VPS | Von OVH keiner dokumentiert. Es gibt einen Rescue-Modus, das Schreiben eines Images daraus ist nicht beschrieben [R10]. | Nein. |
| AWS EC2 | Nach S3 hochladen, als Snapshot importieren, als AMI registrieren [R11]. | Ja, als öffentliches AMI, je Region kopiert [R12]. |
| Microsoft Azure | Eine VHD fester Größe hochladen und eine Image-Version in einer Compute Gallery anlegen [R13]. | Ja, über eine Community Gallery [R14]. |
| Google Cloud | `disk.raw` in einem gzip-komprimierten tar nach Cloud Storage hochladen und daraus ein Image anlegen [R15]. | Ja, für alle authentifizierten Nutzer, global [R16]. |

AWS, Azure und Google Cloud sind nach Entscheidung des Projektinhabers vom 2026-11-12 geplante Ziele: Sie gehören zum Umfang und werden nach den Referenzzielen vollständig angebunden (siehe §A). Nicht festgestellt: ob einer dieser Wege mit dem Appliance-Image funktioniert, weil keiner ausprobiert wurde; mit welcher Firmware die x86-Server der Hetzner Cloud booten, was Hetzners Dokumentation nicht angibt; und wie viel CPU, Arbeitsspeicher und Speicherplatz die Core-Dienste brauchen. Die Zitate hinter der Tabelle stammen aus den abgerufenen Seiten und wurden nicht Byte für Byte mit den Originalen verglichen.

Die Referenzziele für gehostete und private VMs haben eine gemeinsame Basis, die §H verbindlich macht. Festgestellt aus der obigen Recherche und aus der Dokumentation von Proxmox VE, Version 9.2.13:

| Merkmal | Hetzner Cloud | OVHcloud Public Cloud | Proxmox VE | Gemeinsame Basis |
|---------|---------------|-----------------------|------------|------------------|
| Angenommenes Artefakt | Raw-Image, aus dem Rescue-System geschrieben [R3] | Upload als raw oder qcow2 [R7] | Import eines Raw-, qcow2- oder vmdk-Images; Installer-ISO [R18] | Raw-Disk-Image |
| Plattengerät | virtio [R20] | virtio-scsi im Beispiel von OVH [R7] | VirtIO SCSI für neue Linux-VMs in der Weboberfläche, ein emulierter LSI-Controller als Standard der Kommandozeile [R17][R18] | virtio-scsi, dazu der emulierte Standard von Proxmox VE |
| Netzwerkgerät | virtio [R20] | Nicht dokumentiert | Standardmäßig Intel E1000, VirtIO empfohlen [R17] | virtio-net, dazu E1000 |
| Firmware | Nicht dokumentiert | Nicht dokumentiert | Standardmäßig SeaBIOS, OVMF wählbar [R17][R18] | Legacy-BIOS und zusätzlich UEFI |
| Netzwerkkonfiguration | IPv4 per DHCP [R21] | Über Metadaten; DHCP nicht dokumentiert | Ohne cloud-init nicht von der Plattform geliefert [R19] | DHCP-Client |
| Provisionierungsdaten | Metadata-Server, von cloud-init gelesen [R3] | Metadata-Server, von cloud-init gelesen [R22] | Optionales cloud-init-Laufwerk im NoCloud-Format [R19] | cloud-init-kompatible Quelle, deren Existenz nicht garantiert ist |

Außerhalb der gemeinsamen Basis liegen das Installer-ISO, das nur Proxmox VE und Mini-PCs annehmen, Treiber für physische Hardware, die nur Mini-PCs und dedizierte OVHcloud-Server brauchen, und OVHcloud VPS, für die OVH keinen Weg dokumentiert.

Abgrenzung: `spec/distribution-requirements/` legt fest, was die Basis-Distribution leisten muss. Dieses Spec legt fest, wo die Appliance läuft und was sich zwischen diesen Orten unterscheidet. Das Verhalten der Anwendung gehört zu `nolte/kamerplanter`.

Leser: Maintainer, die die Appliance bauen und veröffentlichen, Reviewer, die entscheiden, ob ein Release ein Ziel für sich beanspruchen darf, und Autoren der Installationsdokumentation.

## Ziele

- Eine Appliance bedient gehostete Server, private Virtualisierung und kleine private Hardware und lässt dem Nutzer möglichst freie Wahl zwischen ihnen.
- Der Betriebsaufwand ist auf jedem Ziel gleich gering: nirgends Patchen, Benutzerverwaltung oder Baselining durch den Nutzer.
- Ein Nutzer wählt ein Ziel nach dem, was er besitzt oder mietet, und nicht nach dem, was die Appliance zufällig unterstützt.
- Die Appliance verhält sich auf jedem Ziel gleich; nur der Weg auf die Maschine unterscheidet sich.
- Jedes Ziel, das ein Release für sich beansprucht, wurde mit diesem Release geprüft.

## Nicht-Ziele

- Verwaltete Plattformen: Kubernetes-Dienste, Container-as-a-Service- und Platform-as-a-Service-Angebote.
- Cluster oder Installationen über mehrere Maschinen.
- Raspberry Pi und andere aarch64-Maschinen. Sie sind zurückgestellt, nicht verworfen; siehe Offene Fragen.
- Andere Architekturen als x86_64.
- Eine Garantie für jeden Hosting-Anbieter, Hypervisor oder Einplatinenrechner am Markt.
- Dimensionierung für die optionalen Dienste (`vectordb`, `ollama`, `timescaledb`).

## Anforderungen

### A. Zielklassen

- **A1 MUSS [MUST]** in drei Zielklassen installierbar sein: gehostete VM (ein bei einem Anbieter gemieteter virtueller Server), private VM (ein Gast auf einem vom Nutzer betriebenen Hypervisor) und private Hardware (eine kleine physische Maschine im Besitz des Nutzers).
- **A2 MUSS [MUST]** diese als Referenzziele behandeln: Hetzner Cloud und OVHcloud für gehostete VM, Proxmox VE für private VM und x86_64-Mini-PCs nach Art des Intel NUC für private Hardware.
- **A3 MUSS [MUST]** auf jedem Ziel dieselben Dienste, denselben Update-Mechanismus und dieselbe Version bieten; Unterschiede beschränken sich auf Artefaktformat, Hardware-Unterstützung und Provisionierungseingaben.
- **A4 SOLLTE [SHOULD]** auf anderen Zielen derselben Klasse ohne zielspezifische Änderungen laufen.
- **A5 MUSS [MUST]** in der Dokumentation zwischen Referenzzielen, die geprüft sind, geplanten Zielen, die angekündigt, aber noch nicht geprüft sind, und anderen Zielen unterscheiden, bei denen der Betrieb nur erwartet wird.
- **A6 DARF NICHT [MUST NOT]** für den Betrieb von einem anbieterspezifischen Dienst oder einer anbieterspezifischen API abhängen.
- **A7 MUSS [MUST]** AWS EC2, Microsoft Azure und Google Cloud als geplante Ziele behandeln: gehostete VM-Ziele, die nach den Referenzzielen angebunden werden.
- **A8 DARF NICHT [MUST NOT]** für die Referenzziele eine Designentscheidung treffen, die ein geplantes Ziel ausschließt.
- **A9 MUSS [MUST]** ein geplantes Ziel erst dann zum Referenzziel machen, wenn die Verifikation aus §G dafür eingerichtet ist.

### B. Architekturen

- **B1 MUSS [MUST]** x86_64 in allen drei Zielklassen unterstützen.
- **B2 MUSS [MUST]** nur Container-Images ausführen, die für die Architektur der Maschine veröffentlicht sind, ohne CPU-Emulation.

### C. Auslieferungsartefakte

- **C1 MUSS [MUST]** für private VMs ein Installer-ISO bereitstellen.
- **C2 MUSS [MUST]** sich auf x86_64-Mini-PCs von demselben ISO installieren lassen, das auf ein USB-Medium geschrieben wurde.
- **C3 MUSS [MUST]** für gehostete VMs ein vorinstalliertes Disk-Image im Raw-Format bereitstellen, das der Nutzer mit den Self-Service-Mitteln des Anbieters ausrollen kann, ohne Support-Anfrage.
- **C4 MUSS [MUST]** alle Artefakte einer Version aus einer Quelldefinition bauen, wie `spec/distribution-requirements/` §H es verlangt.
- **C5 MUSS [MUST]** jedes Artefakt mit Prüfsumme und Signatur veröffentlichen.
- **C6 MUSS [MUST]** jedes anbieterspezifische Image-Format aus dem einen Raw-Disk-Image ableiten statt aus einem separaten Build.

### D. Hardware und Plattform

- **D1 MUSS [MUST]** auf gehosteten und privaten VMs mit den virtuellen Geräten laufen, die die Referenzplattformen standardmäßig zuweisen.
- **D2 MUSS [MUST]** auf x86_64-Mini-PCs mit kabelgebundenem Ethernet und internem SATA- oder NVMe-Speicher laufen.
- **D3 SOLLTE [SHOULD]** erlauben, dass der Datenort auf einem anderen Speichergerät liegt als das System.
- **D4 MUSS [MUST]** allein mit kabelgebundenem Ethernet arbeiten.
- **D5 KANN [MAY]** WLAN auf privater Hardware unterstützen.
- **D6 MUSS [MUST]** Mindestwerte für CPU, Arbeitsspeicher und Speicherplatz je Zielklasse veröffentlichen, gestützt auf Messungen.
- **D7 MUSS [MUST]** die Core-Dienste ohne GPU ausführen.
- **D8 MUSS [MUST]** auf privater Hardware nach einem abrupten Stromausfall ohne manuelle Reparatur den Betrieb wieder aufnehmen.

### E. Einrichtung je Umgebung

- **E1 MUSS [MUST]** auf gehosteten VMs Hostname, Netzwerkkonfiguration und Administrator-SSH-Schlüssel aus den Instanz-Metadaten des Anbieters übernehmen.
- **E2 MUSS [MUST]** auf privaten VMs und privater Hardware per DHCP hochkommen, ohne jegliche Provisionierungsdaten.
- **E3 MUSS [MUST]** auf privater Hardware nach der Installation ohne angeschlossenen Monitor oder angeschlossene Tastatur laufen.
- **E4 SOLLTE [SHOULD]** sich im lokalen Netz unter einem festen Namen bekannt machen, sodass der Nutzer die Web-UI findet, ohne eine Adresse nachzuschlagen.

### F. Netzwerk-Exposition

- **F1 MUSS [MUST]** auf gehosteten VMs TLS für die Web-UI und die API anbieten.
- **F2 DARF NICHT [MUST NOT]** die Web-UI oder die API auf einer öffentlichen Adresse über unverschlüsseltes HTTP ausliefern, sofern der Nutzer das nicht ausdrücklich entschieden hat.
- **F3 MUSS [MUST]** auf privaten Zielen ohne eingehende Erreichbarkeit aus dem Internet, ohne öffentlichen DNS-Namen und ohne Portweiterleitung funktionieren.
- **F4 MUSS [MUST]** Updates allein über ausgehende Verbindungen beziehen.
- **F5 MUSS [MUST]** die Core-Dienste ohne Internetverbindung funktionsfähig halten, sobald der erste Start abgeschlossen ist.
- **F6 SOLLTE [SHOULD]** IPv4 und IPv6 unterstützen.

### G. Verifikation

- **G1 MUSS [MUST]** jedes Release vor der Veröffentlichung auf jedem Referenzziel installieren und per Smoke-Test prüfen.
- **G2 SOLLTE [SHOULD]** diese Verifikation für gehostete und private VMs automatisieren.
- **G3 KANN [MAY]** private Hardware manuell verifizieren, mit einem schriftlichen Protokoll je Release.
- **G4 MUSS [MUST]** eine Kompatibilitätsliste veröffentlichen, die Ziel, Architektur, Artefakt und die zuletzt geprüfte Version nennt.

### H. Gemeinsame Basis der Referenzziele

- **H1 MUSS [MUST]** das vorinstallierte Raw-Disk-Image als das Artefakt bereitstellen, das jedes Referenzziel der Klassen gehostete VM und private VM annimmt.
- **H2 MUSS [MUST]** dieses Image als KVM-Gast mit virtio-Speicher- und -Netzwerkgeräten booten.
- **H3 MUSS [MUST]** dieses Image mit den Geräten booten, die Proxmox VE standardmäßig zuweist, einschließlich der emulierten.
- **H4 MUSS [MUST]** dieses Image unter Legacy-BIOS und unter UEFI booten.
- **H5 MUSS [MUST]** seine IPv4-Konfiguration ohne Nutzereingriff per DHCP beziehen.
- **H6 MUSS [MUST]** Provisionierungsdaten aus der cloud-init-kompatiblen Quelle des Ziels lesen, wenn eine vorhanden ist.
- **H7 MUSS [MUST]** starten und seine Ersteinrichtung abschließen, wenn keine Provisionierungsdaten vorhanden sind.
- **H8 MUSS [MUST]** auf die kleinste Platte passen, die ein Referenzziel anbietet, und beim ersten Boot auf die verfügbare Platte wachsen.
- **H9 DARF NICHT [MUST NOT]** von einem Image abhängen, das der Hersteller innerhalb eines Anbieters teilt oder veröffentlicht.
- **H10 MUSS [MUST]** H1 bis H9 auf jedem Ziel mit demselben Systeminhalt erfüllen; das Installer-ISO, Treiber für physische Hardware und anbieterspezifische Formate erweitern diesen Inhalt und ersetzen ihn nicht.

## Akzeptanzkriterien

Die Kriterien fassen mehrere Anforderungen zusammen; jede Anforderung bleibt für sich normativ.

- [ ] Ein Release installiert sich auf Hetzner Cloud, OVHcloud, Proxmox VE und einem x86_64-Mini-PC, und die Web-UI antwortet auf jedem davon (A1, A2, B1).
- [ ] Jede dieser Installationen meldet dieselbe Appliance-Version und führt dieselbe Menge an Core-Diensten aus (A3).
- [ ] Die Installation auf jedem gehosteten Referenzziel nutzt nur die Self-Service-Oberfläche des Anbieters (C3).
- [ ] Die Appliance läuft auf einer gehosteten VM, während die Anbieter-API unerreichbar ist (A6).
- [ ] Die Dokumentation nennt AWS EC2, Microsoft Azure und Google Cloud als geplant und beansprucht keines davon als geprüft (A5, A7).
- [ ] Für jedes geplante Ziel hält ein schriftlicher Nachweis fest, welche seiner dokumentierten Image-Anforderungen das aktuelle Image erfüllt und welche nicht (A8).
- [ ] Ein Ziel erscheint nur in solchen Releases als Referenzziel, deren Kompatibilitätsliste eine geprüfte Version dafür führt (A9).
- [ ] Kein Container läuft unter CPU-Emulation (B2).
- [ ] Das ISO installiert einen Proxmox-VE-Gast und, auf ein USB-Medium geschrieben, einen x86_64-Mini-PC (C1, C2, D1, D2).
- [ ] Alle Artefakte eines Releases stammen aus einem Build-Lauf, jedes anbieterspezifische Format ist aus dem Raw-Disk-Image konvertiert, und jedes Artefakt trägt eine Prüfsumme und eine gültige Signatur (C4, C5, C6).
- [ ] Eine gehostete VM ist per SSH mit dem bei der Erstellung hinterlegten Schlüssel unter dem bei der Erstellung hinterlegten Hostnamen erreichbar, ohne Konsolenzugang (E1).
- [ ] Ein installierter Mini-PC, an dem nur Strom und Ethernet angeschlossen sind, bootet bis zur funktionierenden Web-UI (D4, E2, E3).
- [ ] Die Core-Dienste laufen auf einer Maschine ohne GPU (D7).
- [ ] Nachdem auf privater Hardware im Betrieb der Strom getrennt wurde, antwortet die Web-UI ohne manuellen Eingriff wieder (D8).
- [ ] Die Web-UI und die API einer gehosteten VM antworten über TLS, und unverschlüsseltes HTTP auf der öffentlichen Adresse wird in der Standardkonfiguration abgelehnt (F1, F2).
- [ ] Eine private Installation hinter NAT ohne Portweiterleitung erhält ein Update (F3, F4).
- [ ] Wird die Internetverbindung nach dem ersten Start getrennt, antworten die Core-Dienste weiter, auch über einen Neustart hinweg (F5).
- [ ] Die Dokumentation nennt die Mindestressourcen je Zielklasse und welche Ziele geprüft sind (A5, D6).
- [ ] Die Kompatibilitätsliste des Releases nennt jedes Referenzziel mit Architektur, Artefakt und geprüfter Version (G1, G4).
- [ ] Das Raw-Disk-Image bootet auf Hetzner Cloud, auf dem OVHcloud-Referenzprodukt und auf Proxmox VE bis zur funktionierenden Web-UI, und alle drei melden dieselbe System-Image-Kennung (H1, H2, H10).
- [ ] Auf Proxmox VE bootet das Image in einer VM mit den Standardgeräten und in einer mit VirtIO-Geräten, unter SeaBIOS und unter OVMF (H3, H4).
- [ ] Das Image bezieht seine Adresse per DHCP, übernimmt Hostname und SSH-Schlüssel, wo das Ziel Provisionierungsdaten liefert, und schließt die Ersteinrichtung auf einer Proxmox-VE-VM ohne cloud-init-Laufwerk ab (H5, H6, H7).
- [ ] Das Image passt auf den kleinsten Servertyp jedes gehosteten Referenzziels und nutzt nach dem ersten Boot die ganze Platte (H8).
- [ ] Kein Installationsweg stützt sich auf ein Image, das der Hersteller innerhalb eines Anbieters veröffentlicht hat (H9).

## Referenzen

- Quellen abgerufen am 2026-11-12.
- [R1] Hetzner Docs, „Cloud-ISO installation - configure gateway“, zuletzt geändert am 2023-12-28 (P): <https://docs.hetzner.com/cloud/servers/iso-installation-gateway/>
- [R2] Hetzner Docs, Cloud-Server-FAQ, „How can I get a custom ISO?“, zuletzt geändert am 2024-09-12 (P): <https://docs.hetzner.com/cloud/servers/faq#how-can-i-get-a-custom-iso>
- [R3] Hetzner-Cloud-API-Referenz, Images und Server Actions (P): <https://docs.hetzner.cloud/>
- [R4] Hetzner Docs, FAQ zu Backups und Snapshots, zuletzt geändert am 2022-08-23 (P): <https://docs.hetzner.com/cloud/servers/backups-snapshots/faq/>
- [R5] Packer-Plugin für die Hetzner Cloud, von Hetzner gepflegt (P): <https://github.com/hetznercloud/packer-plugin-hcloud>
- [R6] `hcloud-upload-image`, Community-Werkzeug ohne Hetzner-Support (P): <https://github.com/apricote/hcloud-upload-image>
- [R7] OVHcloud Docs, eigenes Image in die Public Cloud hochladen (P): <https://docs.ovhcloud.com/en/guides/public-cloud/compute/upload-own-image>
- [R8] OVHcloud Docs, Images zwischen Projekten teilen (P): <https://docs.ovhcloud.com/en/guides/public-cloud/compute/share-images-between-projects>
- [R9] OVHcloud Docs, Bring Your Own Image, aktualisiert am 2026-08-05 (P): <https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/bring-your-own-image>
- [R10] OVHcloud Docs, Rescue-Modus für VPS, aktualisiert am 2026-09-07 (P): <https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/rescue>
- [R11] AWS VM Import/Export, Import einer Disk als Snapshot (P): <https://docs.aws.amazon.com/vm-import/latest/userguide/vmimport-import-snapshot.html>
- [R12] Amazon EC2, ein AMI öffentlich machen (P): <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/sharingamis-intro.html>
- [R13] Microsoft Learn, ein generisches Linux-Image für Azure vorbereiten (P): <https://learn.microsoft.com/en-us/azure/virtual-machines/linux/create-upload-generic>
- [R14] Microsoft Learn, Images über eine Community Gallery teilen (P): <https://learn.microsoft.com/en-us/azure/virtual-machines/share-gallery-community>
- [R15] Google Cloud, Boot-Disk-Images manuell importieren (P): <https://cloud.google.com/compute/docs/import/import-existing-image>
- [R16] Google Cloud, Zugriff auf eigene Images verwalten (P): <https://cloud.google.com/compute/docs/images/managing-access-custom-images>
- [R17] Proxmox VE Administration Guide, „QEMU/KVM Virtual Machines“, Version 9.2.13 (P): <https://pve.proxmox.com/pve-docs/chapter-qm.html>
- [R18] Proxmox VE, Handbuchseite `qm(1)`, Version 9.2.13 (P): <https://pve.proxmox.com/pve-docs/qm.1.html>
- [R19] Proxmox-VE-Wiki, „Cloud-Init Support“, zuletzt bearbeitet am 2025-11-19 (P): <https://pve.proxmox.com/wiki/Cloud-Init_Support>
- [R20] Hetzner Docs, FAQ zu technischen Details der Cloud, zuletzt geändert am 2024-06-25 (P): <https://docs.hetzner.com/cloud/technical-details/faq/>
- [R21] Hetzner Docs, statische IP-Konfiguration, zuletzt geändert am 2024-06-12 (P): <https://docs.hetzner.com/cloud/servers/static-configuration/>
- [R22] OVHcloud Docs, FAQ zur Public Cloud (P): <https://docs.ovhcloud.com/en/guides/public-cloud/cross-functional/faq-pci>

## Offene Fragen

- **Raspberry Pi (zurückgestellt).** Nach Entscheidung des Projektinhabers vom 2026-11-12 nicht im Umfang, später wieder aufzugreifen. Was dafür bekannt ist: Die Backend- und Frontend-Images von Kamerplanter sind nur für `linux/amd64` veröffentlicht (siehe Kontext), `nolte/kamerplanter` muss also zuerst aarch64-Images veröffentlichen. Das Ziel zurückzuholen bedeutet: aarch64 als zweite Architektur, die gemeinsam mit x86_64 veröffentlicht wird, ein Image, das auf das Boot-Medium geschrieben wird und ohne Installer-Schritt startet, eine benannte Liste unterstützter Modelle, eine Entscheidung zwischen SD-Karte und USB- oder NVMe-Speicher sowie die Einrichtung ohne Monitor oder Tastatur.
- **Mindestressourcen.** D6 verlangt veröffentlichte Mindestwerte; es gibt keine, weil nichts gemessen wurde.
- **Import in der Hetzner Cloud.** Kein Hersteller kann dort ein Image veröffentlichen, also muss jeder Nutzer das Disk-Image in sein eigenes Projekt importieren. Ob der dokumentierte Weg Hetzners Packer-Plugin oder das Community-Werkzeug ist, ist nicht entschieden, und keines wurde ausprobiert. Hetzner sichert nicht zu, dass die cloud-init-Provisionierung auf einem über das Rescue-System installierten System funktioniert, wovon E1 abhängt.
- **Bootmodus des Disk-Images.** H4 verlangt beide Bootmodi, weil die Firmware bei zwei der drei Ziele nicht bekannt ist. Hetzners Dokumentation nennt die Firmware seiner x86-Server nicht, und eine Drittquelle berichtet Legacy-BIOS; die von OVH nennt sie ebenfalls nicht; Proxmox VE nutzt standardmäßig SeaBIOS [R17]. Unter den geplanten Zielen nutzt AWS auf x86 standardmäßig Legacy-BIOS, und die Importseite von Google Cloud verlangt einen MBR-Bootloader. Dass ein Image unter beiden bootet, ist nicht verifiziert.
- **Ein Image oder ein Image je Ziel.** H10 verlangt überall denselben Systeminhalt. Manche Immutable-Distributionen legen die Provisionierungsplattform im Image fest, sodass jedes Ziel eine eigene Variante mit sonst identischem Inhalt braucht. Ob solche Varianten H10 und C6 erfüllen, ist nicht entschieden und hängt von der gewählten Distribution ab.
- **Anbindung der geplanten Ziele.** AWS, Azure und Google Cloud haben jeweils einen Self-Service-Importweg und erlauben öffentliches Teilen ohne Marketplace-Eintrag. Sie anzubinden bedeutet je ein weiteres Artefaktformat (Azure braucht eine VHD fester Größe, Google Cloud ein `disk.raw` in einem tar-Archiv), anbieterspezifische Treiber und Provisionierungs-Clients im Image und ein Konto je Anbieter für die Verifikation nach G1. Reihenfolge und Zeitpunkt sind nicht entschieden. Eine Unsicherheit ist bekannt: Der AWS-Importweg mit Betriebssystem-Prüfung nimmt nur gelistete Distributionen an, und die Dokumentation sagt nicht, dass der Snapshot-Weg eine nicht gelistete annimmt.
- **Welche OVH-Produkte.** OVHcloud verkauft VPS, Public-Cloud-Instanzen und dedizierte Server. Public Cloud und dedizierte Server haben einen dokumentierten Weg für ein eigenes Image, VPS hat keinen. Welche davon als Referenzziel zählen, ist nicht entschieden.
- **TLS auf gehosteten VMs.** F1 verlangt TLS, aber ein öffentlich vertrauenswürdiges Zertifikat braucht einen DNS-Namen, den der Nutzer kontrolliert. Ob die Appliance Zertifikate selbst bezieht oder mit einem selbstsignierten startet, ist nicht entschieden.
- **Backup auf privater Hardware.** Virtualisierte Ziele können sich auf Hypervisor-Snapshots stützen. Private Hardware hat keine, und wie der Nutzer dort den Datenort sichert, ist nicht entschieden.
- **Verifikations-Hardware.** G1 verlangt für jedes Release einen Test auf echter privater Hardware. Welche Geräte dafür verfügbar sind und wer den Test ausführt, ist nicht entschieden.
