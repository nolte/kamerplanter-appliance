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
| `SHA256SUMS` | SHA-256-Prüfsummen aller Dateien des Releases |
| `*.sigstore.json` | schlüssellose Signatur-Bundles für das Image und für `SHA256SUMS` |
| `kamerplanter-appliance-<version>-source-commit.txt` | der Commit, aus dem das Image gebaut wurde |

Der Release-Workflow signiert mit seiner eigenen Identität; einen privaten Schlüssel gibt es nicht. Jede der folgenden Prüfungen schlägt für eine Datei fehl, die nicht der Release-Workflow dieses Repositorys gebaut hat, auch für eine in einem Fork neu gebaute Kopie.

## Mit cosign

Funktioniert ohne GitHub-Konto und, sobald die Dateien heruntergeladen sind, ohne Netzzugang zu GitHub:

```bash
cosign verify-blob \
  --bundle kamerplanter-appliance-v0.1.0-x86_64.raw.xz.sigstore.json \
  --certificate-identity "https://github.com/nolte/kamerplanter-appliance/.github/workflows/release-publish.yml@refs/heads/develop" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  kamerplanter-appliance-v0.1.0-x86_64.raw.xz
```

## Mit der GitHub-CLI

Prüft die beim Release festgehaltene Herkunftsbescheinigung:

```bash
gh attestation verify kamerplanter-appliance-v0.1.0-x86_64.raw.xz \
  --repo nolte/kamerplanter-appliance \
  --signer-workflow nolte/kamerplanter-appliance/.github/workflows/release-publish.yml
```

Releases dieses Repositorys sind unveränderlich, daher lässt sich zusätzlich bestätigen, dass eine Datei genau das Asset eines veröffentlichten Releases ist:

```bash
gh release verify-asset v0.1.0 kamerplanter-appliance-v0.1.0-x86_64.raw.xz --repo nolte/kamerplanter-appliance
```

## Nur Prüfsummen

`sha256sum --check --ignore-missing SHA256SUMS` bestätigt, dass ein Download vollständig ist. Woher die Datei stammt, beweist das nur, wenn `SHA256SUMS` selbst mit einem der Kommandos oben geprüft wurde.
