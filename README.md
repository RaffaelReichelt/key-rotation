# Automatische Rotation der Tailscale Auth Keys (Docker Swarm Secret)

Da Auth Keys maximal 90 Tage gültig sind, ist eine automatische Rotation sinnvoll.

## Architektur der Rotation

- Das Script [`scripts/rotate-ts-authkey.sh`](scripts/rotate-ts-authkey.sh) läuft auf einem Swarm-Manager und verwendet einen Tailscale OAuth Client.
- Es holt damit ein kurzlebiges API-Access-Token (ca. 1h) und erzeugt per Tailscale API einen frischen Auth Key.
- Der Key wird als Docker Swarm Secret `ts_authkey` abgelegt (Name per `SECRET_NAME` änderbar). Die `.env` und die Compose-Dateien werden nicht angefasst.

Docker Secrets sind unveränderlich und lassen sich nicht löschen, solange ein Service sie nutzt. Deshalb läuft die Rotation in zwei Phasen, bei denen kein Service ohne Secret dasteht:

1. Neuer Key wird als `ts_authkey_rotating` angelegt. In allen Services, die `ts_authkey` einbinden, wird das Secret per `docker service update` dagegen getauscht (Zielpfad `/run/secrets/ts_authkey`, uid, gid und mode bleiben gleich).
2. `ts_authkey` wird gelöscht und mit dem neuen Key neu angelegt. Die Services werden zurückgetauscht, danach wird `ts_authkey_rotating` entfernt.

Die betroffenen Services werden pro Phase einmal neu gestartet (Rolling Update). Sidecars mit persistiertem State (`tailscale-state`-Volume) verbinden sich ohne den Key wieder; der Key wird nur bei der Erstanmeldung gebraucht.

Bricht ein Lauf zwischen den Phasen ab, bleibt `ts_authkey_rotating` in Gebrauch. Das Script verweigert dann den nächsten Lauf, bis das manuell geklärt ist.

## 1) Installation

```bash
sudo install -m 755 scripts/rotate-ts-authkey.sh /usr/local/sbin/
sudo install -d -m 700 /etc/tailscale-authkey-rotate
sudo install -m 600 .rotation.env.example /etc/tailscale-authkey-rotate/rotation.env
sudo $EDITOR /etc/tailscale-authkey-rotate/rotation.env
```

Werte setzen: `TS_TAILNET`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET`. Die übrigen Werte können in der Regel so bleiben (`TS_KEY_EXPIRY_SECONDS=2592000` = 30 Tage).

Voraussetzungen: `curl`, `jq`, `flock`, `docker`, Ausführung als root auf einem Swarm-Manager.

## 2) Einmaliger manueller Test

```bash
sudo /usr/local/sbin/rotate-ts-authkey.sh
```

## 3) systemd Automation aktivieren

```bash
sudo cp systemd/tailscale-authkey-rotate.service /etc/systemd/system/
sudo cp systemd/tailscale-authkey-rotate.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-authkey-rotate.timer
```

Status prüfen:

```bash
systemctl list-timers | grep tailscale-authkey-rotate
journalctl -u tailscale-authkey-rotate.service
```

## Benötigte OAuth-Berechtigung

Der OAuth Client braucht die Berechtigung, Auth Keys zu erzeugen (`auth_keys` Write). Bei gesetzten Tags (z. B. `tag:swarm`) muss er diese Tags ebenfalls vergeben dürfen.
