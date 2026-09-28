# homectrl-updates

Auto-Update Feed für **homeCtrl** Agent.

Agenten pollen `manifest.json` alle `autoUpdateIntervalMinutes` (Standard 60 min).
Wenn der SHA-256 im Manifest sich vom lokalen Exe-Hash unterscheidet, wird die
Exe unter `url` heruntergeladen, verifiziert und installiert.

## Setup (einmalig)

### 1. Repo auf GitHub erstellen

Auf https://github.com/new:
- Owner: `sayamuhbani59-collab` (dein Account)
- Name: `homectrl-updates`
- Public
- ohne README / gitignore

### 2. Lokal initialisieren + pushen

```powershell
cd C:\Users\mohba\OneDrive\Desktop\pranks\homectrl-updates
git init
git branch -M main
git add .
git commit -m "initial"
git remote add origin https://github.com/sayamuhbani59-collab/homectrl-updates.git
git push -u origin main
```

### 3. Erstes Release hochladen

Über die Web-UI (einfachste Variante):
1. https://github.com/sayamuhbani59-collab/homectrl-updates/releases/new
2. Tag `v1.0.0` erstellen
3. `C:\Users\mohba\OneDrive\Desktop\pranks\Agent\Source\publish_out\homeCtrl.exe` als Asset hochladen
4. Publish

Oder mit `gh` CLI:
```powershell
winget install --id GitHub.cli
gh auth login
gh release create v1.0.0 C:\Users\mohba\OneDrive\Desktop\pranks\Agent\Source\publish_out\homeCtrl.exe --title "v1.0.0" --notes "Initial release"
```

### 4. Config auf allen PCs setzen

In jeder `%LOCALAPPDATA%\homeCtrl\config.json` ergänzen:

```json
{
  "autoUpdateManifestUrl": "https://raw.githubusercontent.com/sayamuhbani59-collab/homectrl-updates/main/manifest.json",
  "autoUpdateIntervalMinutes": 60
}
```

Dann `/reload` in Discord — Auto-Updater startet sofort mit neuen Settings.
Testen: `/checkupdate`.

## Neue Version releasen

Ein Kommando:

```powershell
cd C:\Users\mohba\OneDrive\Desktop\pranks\homectrl-updates
.\release.ps1 -Version 1.0.1 -Notes "Fix screenshot bug"
```

Was `release.ps1` macht:
1. Baut `homeCtrl.exe` neu (self-contained, single-file, x64)
2. Berechnet SHA-256
3. Updated `manifest.json` mit neuer Version + Hash + URL
4. `git commit` + `git push`
5. Wenn `gh` CLI installiert: auto GitHub Release + Exe-Upload

Innerhalb `autoUpdateIntervalMinutes` (Standard 60) ziehen alle laufenden Agenten
die neue Version, installieren via PowerShell + Rollback-Mechanismus und starten sich
selbst neu.

### Flags

- `-SkipBuild` — nur Manifest neu generieren für existierende `publish_out\homeCtrl.exe`
- `-SkipUpload` — nur manifest committen, Exe-Upload manuell (nützlich ohne `gh` CLI)

## Manifest-Format

```json
{
  "version": "1.2.3",
  "sha256": "abc123...",
  "url": "https://github.com/.../homeCtrl.exe",
  "notes": "changelog / kurze Beschreibung"
}
```

- `sha256` = SHA-256 der Exe unter `url` (Manifest wird vor Download geprüft, dann Exe nach Download nochmal)
- `version` nur informativ / Anzeige — Update-Trigger ist Hash-Vergleich
- `notes` optional, wird in `/checkupdate` Response nicht angezeigt (nur intern)

## Debugging

- `/checkupdate` — manueller Check, zeigt Local + Remote Hash
- `/checkupdate force` — installiert neu auch bei identischem Hash (zum Testen)
- Log auf jedem PC: `%LOCALAPPDATA%\homeCtrl\agent.log` — grep `[auto-update]`
