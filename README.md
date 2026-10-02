# Garry's Mod dedicated server container

A Docker image for a Garry's Mod dedicated server, configured entirely through environment variables.

* The image holds no game. The container installs it from Steam on its first start and updates it on every restart.
* One image serves every game branch Steam offers: the stable game (32-bit), the 64-bit `x86-64` branch and the betas.
* `docker exec <container> list-env` lists every variable it reads, with its description and current value.

## Quick start

`docker-compose.yml`:

```yaml
services:
  GarrysModDedicatedServer:
    image: ghcr.io/gameserver-images/garrys-mod:0.1
    restart: unless-stopped
    stop_grace_period: 30s
    env_file:
      - .env
    ports:
      - "27015:27015/udp"
    volumes:
      - server:/home/steam/gmod-dedicated

volumes:
  server:
```

`.env`:

```bash
CVAR_hostname=My server
CVAR_sv_password=
SUPERADMINS=STEAM_0:1:12345678
```

The package is private for now, so log in to GHCR first: `docker login ghcr.io` with a token that has `read:packages`. Then run `docker compose up -d`. The first start downloads the game into the `server` volume. The server is up when the container shows as `healthy`, which means it answers the server browser's queries. `docker exec <container> server-info` shows its name, map, gamemode and players.

The `server` volume holds the game and everything the server keeps: `garrysmod/data`, `garrysmod/sv.db`, addons, workshop downloads and the config files. Back it up, and don't delete it to fix the game: switching `GAME_BRANCH` and back checks every game file.

The container runs as uid 1000. Named volumes work as they are. A bind-mounted folder needs `chown -R 1000:1000 <folder>`.

## Configuration

There are two kinds of variables. `docker exec <container> list-env [filter]` lists them for your own server, with your gamemode's and addons' console variables and the values `server.cfg` sets.

| Variable | Sets | Example |
|---|---|---|
| `CVAR_<name>` | The console variable `name` in `garrysmod/cfg/server.cfg`, which the server runs on every map start | `CVAR_sbox_maxprops=300` |
| Image settings | Game branch, gamemode, map, workshop collection, mounted games, admins, ports and more | `GAMEMODE=terrortown` |

How they apply:

* Variables are written on every start. One you remove leaves its line in `server.cfg`; set it empty to clear the value. Lines you write into `server.cfg` yourself, such as `exec` lines, stay.
* Once the server has listed its console variables (from the second start), names are checked against that list. A name that matches no console variable isn't written, and the log warns about it. `CONFIG_STRICT=true` refuses to start instead. The list depends on the gamemode and the workshop collection, so after changing either the check waits for the next start. The log also warns about variables the image doesn't read at all.
* `CVAR_<name>_FILE`, `STEAM_GSLT_FILE` and `STEAM_API_KEY_FILE` read the value from a file, for Docker secrets. `list-env` shows passwords and tokens as `(set)`.
* `SERVER_ARGS` passes more srcds options, for example `SERVER_ARGS=-disableluarefresh`.

## Game branch

`GAME_BRANCH` picks the game from the "Betas" list in the game's properties in Steam: `public` (the stable game, 32-bit, default), `x86-64` (the 64-bit server) or a beta. Changing it switches the game on the next start, which checks every file and takes a while. Binary modules have to match: `gmsv_*_linux.dll` for 32-bit, `gmsv_*_linux64.dll` for 64-bit.

Every restart brings the game up to date, which matters because updated clients can't join an older server. `GAME_UPDATE=false` starts the installed game without asking Steam, to hold a version.

## Gamemodes, addons and content

* `GAMEMODE` and `MAP` pick the gamemode (by folder name: `sandbox`, `terrortown`, `darkrp`, ...) and the first map. The default is Sandbox on `gm_construct`.
* `WORKSHOP_COLLECTION`: a workshop collection the server downloads on every start. Players download its addons when they join. A workshop gamemode or map has to be in it.
* `GAME_MOUNTS`: games whose content the server mounts, separated by `;`. TTT maps and most gamemodes need Counter-Strike: Source, so `GAME_MOUNTS=cstrike`. The image installs each game's dedicated server into the volume and keeps it up to date. Also available: `hl2mp`, `dod` and `tf`.
* Addons that aren't on the workshop go into `garrysmod/addons` in the volume. To mount a host folder there, mount it at `/home/steam/gmod-dedicated/garrysmod/addons/<name>`.

TTT, for example:

```bash
GAMEMODE=terrortown
MAP=ttt_minecraft_b5
GAME_MOUNTS=cstrike
WORKSHOP_COLLECTION=123456789
CVAR_ttt_preptime_seconds=30
```

## Admins

`SUPERADMINS` and `ADMINS` take SteamIDs separated by `;`, as `STEAM_0:1:23`, `[U:1:47]` or `76561197960265775`. They're written to `garrysmod/settings/users.txt`, which Garry's Mod reads to give players their group. When neither is set, the image leaves that file alone. Admin addons such as ULX keep their own lists.

## Running the server

* `docker stop` (or stopping it in Portainer) sends `quit` to the server, so it shuts down properly.
* `docker exec <container> console <command>` sends a command line to the server console, for example `console say Restart in 5 minutes` or `console status`. The reply shows up in the container log.
* For remote administration, set `CVAR_rcon_password`, publish `27015/tcp` and use any Source RCON client.
* `STEAM_GSLT` takes a [Game Server Login Token](https://steamcommunity.com/dev/managegameservers) for app 4000, which gives the server the same Steam ID on every start.
* `TZ`, for example `Europe/Copenhagen`, sets the time zone of the log.

## Ports

| Port | Use | Variable |
|---|---|---|
| 27015/udp | Game and server browser | `PORT` |
| 27015/tcp | RCON, only if you use it | `PORT` |

Forward the UDP port in your firewall or router, and publish the same port number inside and outside the container: the server tells Steam its own port. If you change `PORT`, change the published port to match.

## Image versions

Images are published to `ghcr.io/gameserver-images/garrys-mod` with these tags:

* `0.1`: the newest 0.1.x version. It gets fixes and new features, but nothing that needs you to change your setup. Use this one.
* `0.1.2`: one exact version.
* `latest`: the newest version, including changes that can need changes to your setup.

Until 1.0.0, a change that needs you to change your setup comes as a new minor version (0.2, 0.3, ...). From 1.0.0 on, the tags follow the usual pattern: `1` for the newest 1.x version, then `1.2` and `1.2.3`.

The [releases page](https://github.com/Gameserver-Images/Garrys-Mod/releases) says what changed in each version and what to change for a new minor (before 1.0.0) or major version.

CI boots every new version on every Steam branch, with Sandbox and with TTT and Counter-Strike: Source, and only publishes it once it runs on the stable game. It also checks Steam every 6 hours and boots the current version on each new game build.

## Building the image

```bash
docker build -t gmod-server .
```
