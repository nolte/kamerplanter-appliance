---
title: Einen Download prüfen
audience: [self-hoster, maintainer]
content_mode: how-to
track: user-docs
last_updated: 2026-11-13
---

# Einen Download prüfen

Prüfe jedes heruntergeladene Disk-Image, bevor du es schreibst oder bootest. Ein Release enthält neben jedem Image:

| Datei | Zweck |
|---|---|
| `kamerplanter-appliance-<version>-x86_64.raw.xz` | das komprimierte Disk-Image |
| `SHA256SUMS` | SHA-256-Prüfsummen des Images und der Commit-Datei, je Dateiname |
| `*.sigstore.json` | schlüssellose Signatur-Bundles für das Image und für `SHA256SUMS` |
| `kamerplanter-appliance-<version>-system-image.txt` | das System-Image in der Registry, aus dem das Disk-Image geschrieben wurde, per Digest |
| `kamerplanter-appliance-<version>-source-commit.txt` | der Commit, aus dem das Image gebaut wurde |

Der Release-Workflow signiert mit seiner eigenen Identität; einen privaten Schlüssel gibt es nicht. Eine Signatur beweist, dass der Release-Workflow dieses Repositorys auf `develop` die Datei gebaut hat. Sie sagt für sich nicht, **zu welchem** Release die Datei gehört, weil jedes Release mit derselben Identität signiert wird. Jeder der folgenden Wege bindet die Datei deshalb zusätzlich an die gewünschte Version.

## Mit der GitHub-CLI (empfohlen)

Releases dieses Repositorys sind unveränderlich. Das bestätigt, dass die Datei genau das Asset des genannten Releases ist:

```bash
gh release verify-asset v0.1.0 kamerplanter-appliance-v0.1.0-x86_64.raw.xz --repo nolte/kamerplanter-appliance
```

Die beim Release festgehaltene Herkunftsbescheinigung lässt sich ebenfalls prüfen:

```bash
gh attestation verify kamerplanter-appliance-v0.1.0-x86_64.raw.xz \
  --repo nolte/kamerplanter-appliance \
  --signer-workflow nolte/kamerplanter-appliance/.github/workflows/release-publish.yml \
  --source-ref refs/heads/develop --deny-self-hosted-runners
```

## Mit cosign, ohne GitHub-Konto

Prüfe die signierte `SHA256SUMS` des Releases und danach das Image gegen sie. `SHA256SUMS` führt das Image unter seinem versionierten Namen, daher scheitert ein Image eines anderen Releases am zweiten Schritt:

```bash
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "https://github.com/nolte/kamerplanter-appliance/.github/workflows/release-publish.yml@refs/heads/develop" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
```

`SHA256SUMS` führt die Signatur-Bundles nicht auf: Sie entstehen danach und sichern ihre Integrität selbst.

## Nur Prüfsummen

`sha256sum --check --ignore-missing SHA256SUMS` allein bestätigt, dass ein Download vollständig ist. Woher die Datei stammt, beweist das nur, wenn `SHA256SUMS` selbst wie oben geprüft wurde.

## Das System-Image in der Registry

Installierte Appliances aktualisieren sich aus `ghcr.io/nolte/kamerplanter-appliance`. Jedes veröffentlichte System-Image trägt zwei Signaturen:

- eine mit dem **Update-Schlüssel**, die jede Appliance prüft, bevor sie ein Update bereitlegt. Sein öffentlicher Teil liegt im Repository unter `image/keys/system-image.pub` und auf jeder Appliance unter `/usr/share/kamerplanter/keys/system-image.pub`. Die Workflow-Identität unten können Appliances noch nicht prüfen, weil die Container-Werkzeuge, die sie nutzen, vorerst nur Schlüssel annehmen.
- eine **schlüssellose** Signatur des Release-Workflows, wie bei den Dateien oben:

```bash
cosign verify ghcr.io/nolte/kamerplanter-appliance@sha256:<digest> \
  --certificate-identity "https://github.com/nolte/kamerplanter-appliance/.github/workflows/release-publish.yml@refs/heads/develop" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Den Digest entnimmst du der Datei `-system-image.txt` des Releases.
