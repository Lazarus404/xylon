# Xylon

**Live rooms for your product** -- audio, video, and realtime data -- without
building a media stack from scratch.

Ported and updated from an earlier Xirsys media server implementation; 
released for public use.

Xylon is a modular WebRTC media server. Your app still owns the UI and identity.
Xylon runs the rooms: it connects each participant over a secure link, and a
pluggable **backend** decides what happens to the media (echo for labs,
multiparty conference, chat-like data fanout, and more).

How the pieces fit (rooms, signaling, backends, Control, ICE): see
[ARCHITECTURE.md](ARCHITECTURE.md). Multi-node rooms: [SCALING.md](SCALING.md).

---

## What problem this solves

Phones and browsers can capture a microphone and camera, but a product still
needs a server that connects people and decides who hears and sees whom. Xylon
is that server layer: sessions (rooms), signaling to set them up, and a Backend
policy per room. Optional Control adds operator APIs (auth, inject, mute, presence).

Xylon is not your login system, CDN, or a recording product by itself.

---

## Quickstart

Goal: hear and see yourself in a browser in a few minutes (Echo lab).

### 1. Prerequisites

- Elixir / Mix for this app
- Node.js for the lab UI
([xylon-test-client](https://github.com/Lazarus404/xylon-test-client))
- A reachable advertise address for ICE (loopback is fine on one machine)

In a workspace that includes sibling packages:

```bash
cd xylon
XTURN_LOCAL_DEPS=1 mix deps.get
```

### 2. Build the lab client

In the [xylon-test-client](https://github.com/Lazarus404/xylon-test-client)
package:

```bash
npm install && npm run build
```

### 3. Start Echo

From the Xylon app directory. `XYLON_ADVERTISED_IP` is required -- without it,
browsers often fail to pick a working media path.

```bash
export XYLON_ADVERTISED_IP=127.0.0.1
XTURN_LOCAL_DEPS=1 mix xylon.echo --http-port 8080
```

Use your LAN or public IP instead of `127.0.0.1` when the browser is not on the
same host.

### 4. Open the UI

http://127.0.0.1:8080/client/

Toggle audio, video, and datachannel in the lab client. You should get your own
media back (echo).

### 5. Optional checks

| Path | URL / notes |
| --- | --- |
| HTTP create + offer | `x-tenant-id` header; `POST /v1/sessions` then `.../offer` |
| SIP WebSocket | `ws://127.0.0.1:8080/sip` (subprotocol `sip`) |
| Echo AOR | `sip:echo@127.0.0.1` |

Lab SIP uses open REGISTER (no digest) and tenant `lab`.

### What next?

| You want | Go here |
| --- | --- |
| Understand rooms, backends, signaling, Control | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Multiparty SFU | [xylon-conference-backend](https://github.com/Lazarus404/xylon-conference-backend) |
| Labeled data fanout | [xylon-datachannel-backend](https://github.com/Lazarus404/xylon_datachannel_backend) |
| Inject / mute / presence from your backend | [Control recipes](#control-recipes) below |
| Rooms across nodes | [SCALING.md](SCALING.md) |
| Browser Control WebSocket helper | [xylon-client-sdk](https://github.com/Lazarus404/xylon-client-sdk) |

---

## Main modules

| Module | Role |
|--------|------|
| `Xylon` | Attach backends; application entry |
| `Xylon.Session` | One room/call: peers, offer/answer, backend callbacks |
| `Xylon.Forwarder` | Hot path for plaintext media plans |
| `Xylon.Signaling` | HTTP and SIP WebSocket adapters |
| `Xylon.Ice` | Host candidate advertise and gather options |
| `Xylon.Backend.Echo` | Lab RTP + datachannel echo |
| `Xylon.Control` | Optional control plane (off by default) |
| `Xylon.Control.Auth` | Lab / HMAC / JWT tenant auth |
| `Xylon.Control.Inject` | Server-originated datachannel publish |
| `Xylon.Control.Router` | REST inject, moderate, presence, history, record |
| `Xylon.Control.Presence` | Room roster and WebSocket push fanout |
| `Xylon.Control.Feeds` | Active A/V publisher index |
| `Xylon.Control.Quota` | Join/inject rate limits and caps |
| `Xylon.Control.Moderation` | Mute/ban flags and audit trail |
| `Xylon.Control.Webhooks` | Async signed webhook delivery + DLQ |
| `Xylon.Control.Grpc.*` | Optional gRPC inject/presence/history |
| `Xylon.Recording` | Pluggable room recording handler (default Null; use [xylon_record](https://github.com/Lazarus404/xylon_record) for `.mjr` stems) |
| `Xylon.Recording.Aggregator` | Multi-home segment wait + one aggregated `recording.completed` |
| `Xylon.Recording.Cluster` | `:erpc` start/stop/report fan-out to cohost Sessions |
| `Xylon.Recording.LayoutSink` | Plan `:record` sink registry for live layout ingest |
| `Xylon.Cluster` / `Xylon.Trunk.*` | Multi-node placement, cascade trunks, migrate |

---

## RFCs and related specs

- [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) -- JSEP (browser offer/answer)
- [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP offer/answer (via [xsdp](https://github.com/Lazarus404/xsdp))
- [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- ICE (via [XGW](https://github.com/Lazarus404/xgw) and `Xylon.Ice`)
- [RFC 3711](https://www.rfc-editor.org/rfc/rfc3711) -- SRTP; DTLS-SRTP keying via [XGW](https://github.com/Lazarus404/xgw)
- [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP (optional lab signaling)
- [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket (optional)
- Control plane HTTP/gRPC -- product APIs; see `lib/xylon/control/`

---

## Config recipes

### Backends

```elixir
# defaults (Echo lab)
config :xylon,
  backends: [Xylon.Backend.Echo],
  default_backend: :echo

# host with datachannel package on the Mix path
config :xylon,
  backends: [Xylon.Backend.Echo, Xylon.Datachannel.Backend],
  default_backend: :datachannel
```

`default_backend` must be among the attached catalogue ids or Application start
fails. Conference and datachannel Backends are separate packages.

### ICE advertise

```elixir
config :xylon, :ice,
  advertised_ip: {203, 0, 113, 10},
  mode: :lite
  # mode: :full, stun_servers: ["stun.l.google.com:19302"]  # Control WS only
```

```bash
export XYLON_ADVERTISED_IP=127.0.0.1
# export XYLON_ADVERTISED_IP=192.168.0.10
# export XYLON_ICE_MODE=full
# export XYLON_STUN_SERVERS=stun.l.google.com:19302
```

Details and modes: [ARCHITECTURE.md](ARCHITECTURE.md) (ICE section) and `Xylon.Ice`.

### Control recipes

Concepts (auth modes, quotas, mute vs kick, WebSocket frames):
[ARCHITECTURE.md](ARCHITECTURE.md) (Optional Control plane).

Enable:

```elixir
config :xylon,
  control: [
    enabled: true,
    auth: :hmac,
    hmac_secret: System.fetch_env!("XYLON_CONTROL_HMAC_SECRET"),
    # grpc_port: 50051,
    webhook_url: System.get_env("XYLON_CONTROL_WEBHOOK_URL"),
    webhook_secret: System.get_env("XYLON_CONTROL_WEBHOOK_SECRET"),
    topics: %{"chat" => %{label: "chat"}},
    quotas: %{max_participants: 50, inject_per_minute: 120, join_per_minute: 60},
    history_limit: 100,
    history_max_bytes: 4096
  ],
  # Optional room recording tap (default Null = no disk writes).
  # For real stems: add {:xylon_record, ...} and set handler: XylonRecord.Handler
  # On stop, Session emits recording.completed / recording.failed to webhook_url
  # (lab: xylon-compose-worker at http://127.0.0.1:8094/v1/webhooks/xylon).
  # Multi-home: the Control-receiving Session coordinates cohosts via :erpc
  # (Xylon.Recording.Cluster); each edge finalizes local stems; Aggregator emits
  # one recording.completed with merged artifacts (shared recording dir / NFS so
  # compose can Stat every path_or_key). Live RTP never rides Erlang distribution.
  # Live layout (Phase 8, opt-in): record/start with layout: true installs a Plan
  # :record sink; optional rtmp_url for ffmpeg RTP/SDP egress. MCU mix audio
  # preferred when present. Coordinator-only on multi-home. Compose copies
  # layout.mp4 beside segment stems (does not janus-pp-rec layout files).
  recording: [handler: Xylon.Recording.Null, dir: "/tmp/xylon-record"]
```

Datachannel lab with Control (needs
[xylon-datachannel-backend](https://github.com/Lazarus404/xylon_datachannel_backend)
on the Mix path):

```bash
XYLON_ADVERTISED_IP=127.0.0.1 \
XYLON_CONTROL_HMAC_SECRET=lab-hmac-secret \
  XTURN_LOCAL_DEPS=1 mix xylon.datachannel --http-port 8080 --control hmac

# JWT:
XYLON_ADVERTISED_IP=127.0.0.1 \
XYLON_CONTROL_JWKS_URL=https://example.com/.well-known/jwks.json \
  XTURN_LOCAL_DEPS=1 mix xylon.datachannel --http-port 8080 --control jwt

# Optional gRPC (HMAC/JWT only):
XYLON_CONTROL_GRPC_PORT=50051 \
XYLON_ADVERTISED_IP=127.0.0.1 \
XYLON_CONTROL_HMAC_SECRET=lab-hmac-secret \
  XTURN_LOCAL_DEPS=1 mix xylon.datachannel --http-port 8080 --control hmac
```

Mint a token (IEx on the running node):

```elixir
ctx = %Xylon.Control.Context{
  tenant_id: "t1",
  session_id: "room-1",
  participant_id: "host",
  capabilities: ["inject", "moderate", "record"]
}
{:ok, token} = Xylon.Control.Auth.mint(ctx)
```

```bash
curl -sS -X POST "http://127.0.0.1:8080/v1/tenants/t1/sessions/room-1/data" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -d '{"payload":"hello","dest":"all","label":"chat"}'

curl -sS -X POST "http://127.0.0.1:8080/v1/tenants/t1/sessions/room-1/moderate" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -d '{"action":"mute","participant_id":"a","reason":"spam","mids":["0"]}'

curl -sS -X POST "http://127.0.0.1:8080/v1/tenants/t1/sessions/room-1/record/start" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -d '{}'

# Omit mode: auto tracks_and_mix when Conference audio is :mcu, else tracks.
# Spoke SFU of hub mix (audio: :sfu) stays tracks. Explicit mode always wins.
# Explicit: {"mode":"tracks"} or {"mode":"tracks_and_mix"}
# Optional SIM/SVC layer pin (handled by xylon_record): video_layer or rid
# curl ... -d '{"video_layer":0}'
# curl ... -d '{"rid":"h"}'

curl -sS "http://127.0.0.1:8080/v1/tenants/t1/sessions/room-1/record" \
  -H "authorization: Bearer $TOKEN"

curl -sS -X POST "http://127.0.0.1:8080/v1/tenants/t1/sessions/room-1/record/stop" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -d '{}'

curl -sS "http://127.0.0.1:8080/v1/tenants/t1/sessions/room-1/presence" \
  -H "authorization: Bearer $TOKEN"

# Live sessions on this edge (capability "sessions"; empty caps allow in lab).
# Token may bind any session_id; list is tenant-scoped.
curl -sS "http://127.0.0.1:8080/v1/tenants/t1/sessions" \
  -H "authorization: Bearer $TOKEN"

# Fleet load (capability "fleet"; counts and ids only; :erpc peers when clustered)
curl -sS "http://127.0.0.1:8080/v1/tenants/t1/fleet/summary" \
  -H "authorization: Bearer $TOKEN"
curl -sS "http://127.0.0.1:8080/v1/tenants/t1/fleet/nodes" \
  -H "authorization: Bearer $TOKEN"
# Drain / undrain a node (body includes node name; accepting true|false)
curl -sS -X POST "http://127.0.0.1:8080/v1/tenants/t1/fleet/accepting" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -d '{"node":"edge_b@127.0.0.1","accepting":false}'

# Lifecycle webhooks (same webhook_url / webhook_secret as recording):
# session.created, session.closed, participant.joined, participant.left.
# Each payload includes tenant_id, session_id, node, region (and participant_id
# for join/leave). Lab: point XYLON_CONTROL_WEBHOOK_URL at a local receiver
# (or interface POST /v1/webhooks/xylon) and join/leave a known room.

curl -sS "http://127.0.0.1:8080/v1/tenants/t1/sessions/room-1/history?label=chat" \
  -H "authorization: Bearer $TOKEN"
```

Protos for optional gRPC: `priv/protos/xylon/control/v1/`.

---

## Related reading

- [ARCHITECTURE.md](ARCHITECTURE.md) -- concepts, layers, backends, Control, ICE
- [SCALING.md](SCALING.md) -- multi-home cascade and cluster labs
- [XGW](https://github.com/Lazarus404/xgw) -- Peer and Listener transport
- [xylon-conference-backend](https://github.com/Lazarus404/xylon-conference-backend)
- [xylon-datachannel-backend](https://github.com/Lazarus404/xylon_datachannel_backend)
- [xylon-client-sdk](https://github.com/Lazarus404/xylon-client-sdk)
- [xylon-test-client](https://github.com/Lazarus404/xylon-test-client)
