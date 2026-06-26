# TCP Tunnel 🔒

Access your work network from home through any firewall — even one that only allows ports 80 and 443.

## How It Works

```
[Home: Flutter App] ──wss://443──► [Relay Server (Railway/VPS)] ◄──wss://443── [Work: Dart Agent]
        │                                                                               │
 localhost:PORT ◄────────────────── TCP tunnel ────────────────────────────► work resource
```

The **work-side agent** dials **outbound** on port 443 — so no inbound firewall rules are needed on the Fortigate.

---

## Components

| Directory | What it is | Runs on |
|---|---|---|
| `flutter_app/` | Flutter desktop/mobile client UI | Home machine |
| `relay_server/` | Node.js WebSocket relay | Railway / VPS |
| `agent/` | Dart CLI agent | Work machine |

---

## Quick Start

### 1. Deploy the Relay Server (Railway — free tier)

1. Push `relay_server/` to a GitHub repo
2. Go to [railway.app](https://railway.app) → New Project → Deploy from GitHub
3. Set environment variable: `AUTH_TOKEN=your-strong-secret`
4. Note your Railway URL, e.g. `https://tcp-tunnel-relay.up.railway.app`

> Railway automatically provides HTTPS/WSS on port 443 — no nginx needed.

**Or run locally for testing:**
```bash
cd relay_server
cp .env.example .env        # edit AUTH_TOKEN
npm start
# Relay runs on ws://localhost:8080
```

### 2. Start the Agent on your Work Machine

```bash
cd agent
dart pub get

# Run directly:
dart run bin/agent.dart --relay wss://tcp-tunnel-relay.up.railway.app --token your-strong-secret

# Or compile to a standalone .exe (no Dart needed on work machine):
dart compile exe bin/agent.dart -o agent.exe
./agent.exe --relay wss://tcp-tunnel-relay.up.railway.app --token your-strong-secret
```

**Run at Windows startup** (as a scheduled task):
```
schtasks /create /tn "TCPTunnelAgent" /tr "C:\path\to\agent.exe --relay wss://... --token ..." /sc onlogon /ru SYSTEM
```

### 3. Run the Flutter App at Home

```bash
cd flutter_app
flutter pub get
flutter run -d windows       # or -d android
```

1. Open **Settings** tab → set Relay URL + Token → **Save**
2. Open **Tunnels** tab → **Add Tunnel**
3. Hit **Connect**

---

## Common Tunnel Examples

| Name | Local Port | Remote Host | Remote Port | Use for |
|---|---|---|---|---|
| RDP | 13389 | 192.168.1.100 | 3389 | Windows Remote Desktop |
| SSH | 10022 | 192.168.1.50 | 22 | SSH to a Linux server |
| Web App | 18080 | 192.168.1.200 | 8080 | Internal web application |
| SQL Server | 11433 | 192.168.1.10 | 1433 | Database access |

After adding e.g. the RDP tunnel and connecting:
```
# On your home machine, open Remote Desktop Connection to:
localhost:13389
```

---

## Architecture & Protocol

### Wire Protocol

**Control messages** (JSON text frames):
```json
{ "type": "auth",      "token": "...", "role": "client|agent" }
{ "type": "auth_ok" }
{ "type": "open",      "channelId": "uuid", "host": "192.168.1.x", "port": 3389 }
{ "type": "opened",    "channelId": "uuid" }
{ "type": "close",     "channelId": "uuid" }
{ "type": "error",     "channelId": "uuid", "message": "..." }
{ "type": "peer_connected" }
{ "type": "peer_disconnected" }
```

**Data frames** (binary WebSocket frames):
```
[0x01 (1 byte)] [channelId ASCII UUID (36 bytes)] [TCP payload (N bytes)]
```

### Flow
```
Flutter                    Relay                     Agent
  │──auth(token,"client")──►│◄──auth(token,"agent")───│
  │◄──auth_ok───────────────│──auth_ok───────────────►│
  │◄──peer_connected────────│──peer_connected─────────►│
  │──open(id,host,port)────►│──open(id,host,port)────►│
  │◄──opened(id)────────────│◄──opened(id)─────────────│
  │══[data]════════════════►│══[data]════════════════►│
  │◄═[data]═════════════════│◄═[data]══════════════════│
```

---

## Security Notes

- **Change `AUTH_TOKEN`** from the default `changeme` before deploying
- Use **`wss://`** (TLS) in production — Railway provides this automatically
- The relay sees encrypted WebSocket frames but cannot read TCP payload content when using TLS
- The agent only opens connections that the **client explicitly requests** — it does not expose all ports

---

## Building the Agent as a Standalone .exe

```bash
cd agent
dart compile exe bin/agent.dart -o agent.exe
```

Copy `agent.exe` to any Windows machine — no Dart runtime required.

---

## Accessing Other Computers on the Same Network 🌐

The TCP Tunnel agent can bridge traffic to any device on the same local area network (LAN) as the work machine.

### 1. Tunneling Services (RDP, SSH, Web Apps)
To access a service on another computer on the work network:
1. In the **Tunnels** tab of the Flutter client, add a new tunnel.
2. Set the `Remote Host` to the target computer's internal LAN IP address (e.g., `192.168.1.100`) instead of `127.0.0.1`.
3. Connect the tunnel. The agent will forward connections from your client to that LAN machine.

### 2. Remote File Explorer (UNC Paths & Network Shares)
To browse files on another network computer:
1. Go to the **Files** tab in the Flutter client.
2. In the path bar, enter a valid UNC/network path (e.g., `\\192.168.1.100\SharedFolder`).
3. If the work computer has network credentials to access that folder, the file explorer will display and manage its files.

> [!WARNING]
> Running active subnet scans (like ping sweeps) to discover other computers on a corporate network may violate your company's IT policies and trigger intrusion alerts. To see devices the work computer already knows about, you can run `arp -a` on the work machine.

---

## Project Structure

```
tcp-tunnel/
├── flutter_app/              # Flutter client (home)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── models/           # TunnelConfig, LogEntry
│   │   ├── services/         # TunnelService, SettingsService
│   │   ├── screens/          # Home, Settings, Logs
│   │   └── widgets/          # TunnelCard, AddTunnelDialog
│   └── pubspec.yaml
│
├── relay_server/             # Node.js relay (Railway/VPS)
│   ├── src/
│   │   ├── server.js         # HTTP + WebSocket server
│   │   ├── session.js        # Client↔Agent bridge
│   │   └── protocol.js       # Frame encoding/decoding
│   ├── .env.example
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── railway.json          # One-click Railway deploy
│
└── agent/                    # Dart CLI agent (work machine)
    ├── bin/agent.dart
    └── lib/
        ├── agent_service.dart
        └── protocol.dart
```
