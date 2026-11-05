# Xylon scaling

**One room. Many machines. Media stays on the fast path.**

This guide is for engineers who have never run a multi-node media server.
It explains what Xylon can do today when one host is not enough -- in a single
datacentre, and across regions -- and how you wire it without turning Erlang
into a media fabric.

Concepts for a single room (Session, Backend, Control): [ARCHITECTURE.md](ARCHITECTURE.md).
Labs and curls: [README.md](README.md).

---

## What problem this solves

A single media node hits two walls:

1. **Density** -- one host cannot hold unbounded WebRTC peers.
2. **Distance** -- a user in Sydney should not hairpin video through London
   just because the "room" process started there.

Xylon scales by splitting **control** (who is in the room, where should this
client join, connect the pipe) from **media** (encrypted audio, video, and
datachannel bytes on the wire).

| Plane | How it travels | What it carries |
| --- | --- | --- |
| Control | Erlang distribution, `libcluster`, `:erpc` | Membership, hub election, placement, trunk setup, track/label announce |
| Media | UDP + SRTP (`XGW.Trunk.Pipe`) between edges | Actual A/V and opaque datachannel payloads |

**Hard rule:** media bytes never ride Distributed Erlang. If you catch yourself
putting RTP in an `:erpc` call, stop -- that path is for metadata only.

---

## Two shapes of scale

```text
  SAME DATACENTRE                         ACROSS REGIONS
  (horizontal workers)                    (multi-home cascade)

  +-----+  +-----+  +-----+               +---------+     +------------+
  | W1  |  | W2  |  | Hub |               | us-west |     | eu-central |
  |edge |  |edge |  |edge |               |   hub   |=====|    hub     |
  +--+--+  +--+--+  +--+--+               +----+----+ UDP +-----+------+
     |        |        |                       |      SRTP      |
     +--------+--------+                       |                |
        sticky place                           v                v
     one home per room                      clients          clients
                                            nearby           nearby
```

**Same datacentre:** many Xylon nodes share a region. Clients are **placed** on
one sticky edge for a room. You grow capacity by adding workers; hub election
picks who coordinates in-region.

**Across regions:** the same logical room (`{tenant_id, session_id}`) lives on
more than one edge. Each user WebRTCs to a nearby node. Edges exchange media
over an explicit **trunk** -- a UDP+SRTP pipe -- not over a full mesh of every
SFU to every SFU, and not by nesting WebRTC between servers.

You can use both: workers inside each region, trunks between regional hubs.

---

## Mental model (new to media scaling?)

Think of a busy restaurant chain:

- **Clients** sit at local tables (WebRTC to a nearby edge).
- **Placement** is the host who seats you (which edge URL to open).
- **Hub** is the shift manager for that city (one elected node per region).
- **Trunk** is the dedicated courier van between kitchens -- not the dining
  room Wi-Fi, and not the manager's walkie-talkie (Erlang).

```text
  Browser ----WebRTC----> Edge A (your city)
                             |
                             | trunk (UDP+SRTP)
                             v
  Browser ----WebRTC----> Edge B (their city)
```

Signaling and "who published what" can hop over `:erpc`. The packets that make
someone hear you go through the trunk.

---

## Same datacentre: scale out horizontally

### What you get

- Cluster membership (optional `libcluster` topologies, or nodes you already
  distributed)
- One **hub** per `region_id` (highest `hub_priority`, then lowest node name)
- **Sticky placement**: first assign pins a room to a node; later `/place` calls
  return the same home
- Mix / HTTP helpers so your gateway knows which `edge_url` to hand the client

### Topology

```text
               region_id = "eu-central-1"
  +--------------------------------------------------+
  |  Node A (worker)   Node B (hub)   Node C (worker)|
  |       \               |                /         |
  |        +---- Node.list / libcluster --+          |
  |                       |                          |
  |              Hub election (ETS)                  |
  +--------------------------------------------------+
                          |
                      GET /place
                   -> sticky edge_url
```

Media between clients on the **same** edge stays local (normal Peer path).
You are not forced to trunk inside one region just because clustering is on.

### Operator path

1. Bootstrap a config sketch:

```bash
mix xylon.cluster.bootstrap
```

2. Enable cluster on each node (same `region_id` in one DC):

```elixir
config :xylon, :cluster,
  enabled: true,
  region_id: "eu-central-1",
  hub_priority: 10,   # higher wins the hub role
  topologies: [       # non-empty starts libcluster; [] = use existing Node.list
    # ... your Cluster.Strategy ...
  ],
  edge_urls: %{
    "eu-central-1" => "https://media-eu.example.com"
  }
```

Env fallbacks when config omits keys: `XYLON_REGION_ID`, `XYLON_HUB_PRIORITY`.
Application config wins when set.

3. Start nodes with a shared Erlang cookie / distribution story (host concern).

4. Check health:

```bash
mix xylon.cluster.status
```

You should see region, nodes, elected hub, and whether **this** node is hub.

5. Seat clients before WebRTC:

```bash
mix xylon.place TENANT SESSION
# or HTTP:
curl 'https://media-eu.example.com/place?tenant_id=T&session_id=S'
```

Response includes `edge_url`, `node`, `region_id`, and `role` (`hub` or
`worker`). First call assigns sticky home (lexicographically smallest node name
among candidates unless sticky already exists). Later calls keep that home.

6. Client connects to that edge and does normal session create / offer
([README.md](README.md)).

### Modules (same DC)

| Piece | Module |
| --- | --- |
| Public API | `Xylon.Cluster` |
| Hub election | `Xylon.Cluster.Hub`, `Xylon.Cluster.HubElection` |
| Sticky home / cohosts | `Xylon.Cluster.Presence` |
| Placement | `Xylon.Cluster.Placement` |
| Live migrate hooks | `Xylon.Cluster.Migrate` |

---

## Across regions: multi-home cascade

### What you get

- The **same** `{tenant_id, session_id}` on two (or more) regional hubs
- Clients join a nearby edge (`multi_home` placement pins toward the hub)
- A **directional SRTP trunk** between hubs carries media
- Announce messages (control) tell the far edge which tracks/labels exist so
  conference / datachannel backends can fan out

### Topology

```text
        us-west-2                         eu-central-1
  +---------------------+           +---------------------+
  | Clients <-> Hub A   |           | Hub B <-> Clients   |
  | Session {T,S}       |           | Session {T,S}       |
  | Forwarder           |           | Forwarder           |
  | :trunk participant  |           | :trunk participant  |
  +----------+----------+           +----------+----------+
             |                                 |
             |        XGW.Trunk.Pipe           |
             +========= UDP + SRTP ============+
                       (not Erlang)
```

Only **hubs** open the cross-region trunk (`Xylon.Cluster.Trunk.connect_hubs/3`
returns `{:error, :not_hub}` otherwise). Workers inside a region still serve
local sticky rooms; cascade orchestration sits on the elected hub.

### MCU audio cascade (hub-mix)

Conference `audio: :mcu` rooms that span regions use **hub-mix**, not re-mix
on every edge (see workspace `MCU_AUDIO.md`):

- Mix hub: `mcu_cascade: :hub` -- decode trunk talkers into the MCU bus; send
  one Opus full-mix RTP down the trunk.
- Spoke: `mcu_cascade: :spoke` with `audio: :sfu` -- SFU local publishers up;
  SFU-fanout the announced `__mcu_mix__` publisher to local listeners.
- `Manager.connect_pair/3` and `connect_remote/3` auto-announce the hub mix
  onto the spoke after the trunk is up.
- Media stays on `XGW.Trunk.Pipe` (UDP+SRTP). Announce remains control-only
  (`:erpc`). Trunk mix is full by default (spoke self-hear accepted); hub opt
  `mcu_spoke_mix_minus: true` excludes that spoke's contributors from the trunk
  mix (local SFU still carries peer talkers on the spoke).

### Multi-home room recording

Control `record/start` and `record/stop` hit one coordinator Session. That edge
fans out the shared `recording_id` over `:erpc` to `Presence.cohosts`, each hub
finalizes local stems only, and `Xylon.Recording.Aggregator` emits one
`recording.completed` with merged artifacts (shared storage path so compose can
read every `path_or_key`). Live RTP never uses Erlang distribution.

### Keys (who encrypts which way)

Each direction has its own write key. Edge A encrypts with `key_ab` /
`salt_ab`; Edge B encrypts with `key_ba` / `salt_ba`. On connect, each side
treats the far key as `remote_write_*`.

Set via Mix env or config (needed for auto-reconnect after failover too):

```bash
export XYLON_TRUNK_KEY_AB=...
export XYLON_TRUNK_SALT_AB=...
export XYLON_TRUNK_KEY_BA=...
export XYLON_TRUNK_SALT_BA=...
```

Or:

```elixir
config :xylon, :cluster,
  trunk_keys: [key_ab: ..., salt_ab: ..., key_ba: ..., salt_ba: ...]
```

### Operator path

1. Deploy **two regions**, each with cluster enabled and a **distinct**
   `region_id`. Confirm each elects its own hub:

```bash
mix xylon.cluster.status
```

2. Load the same directional trunk keys on both hubs.

3. From hub A, connect to hub B (module id is your Backend catalogue id):

```bash
mix xylon.trunk.connect TENANT SESSION edge_b@host :conference
# or :datachannel / :echo
```

In IEx: `Xylon.Cluster.Trunk.connect_hubs({tenant, session}, peer_hub_node, opts)`.

4. Verify the pipe and cohost map:

```bash
mix xylon.trunk.status TENANT SESSION
```

Expect cohosts in both regions and `XGW.Trunk.Pipe` stats moving (`udp_out` /
`udp_in`) when media flows.

5. Seat clients with multi-home placement:

```bash
mix xylon.place TENANT SESSION --multi-home
# or:
curl 'https://.../place?tenant_id=T&session_id=S&multi_home=true&region_hint=us-west-2'
```

6. After local publish, announce remotes so the far Backend can subscribe /
   open labels (control metadata only):

```elixir
Xylon.Trunk.Manager.announce_local_change(peer_hub_node, {tenant, session}, %{
  from_edge: Node.self(),
  participants: [...],
  tracks: [...]
})
```

### Modules (cascade)

| Piece | Module |
| --- | --- |
| Media pipe | `XGW.Trunk.Pipe` ([XGW](https://github.com/Lazarus404/xgw)) |
| Lifecycle | `Xylon.Trunk.Manager` (`connect_remote`, `announce_local_change`, ...) |
| Hub wrapper | `Xylon.Cluster.Trunk` (`connect_hubs`, `reconnect_cohosts`) |
| Inbound inject | `Xylon.Trunk.Bridge` (auto-started with Manager) |
| Announce schema | `Xylon.Trunk.Announce` |
| Backend apply | `Xylon.Trunk.Hooks` |

`Xylon.Trunk.Manager` always starts with the app. Cluster children start when
`:cluster, enabled: true`.

---

## Putting both together

```text
  Region US                         Region EU
  +-------------------+             +-------------------+
  | W  W  Hub --------+---trunk-----+-------- Hub  W  W |
  | sticky place      |  UDP+SRTP   |      sticky place |
  +-------------------+             +-------------------+
           ^                                  ^
           | WebRTC                           | WebRTC
     users near US                      users near EU
```

- **Inside a region:** add workers; placement sticks rooms; hub coordinates.
- **Between regions:** hubs own the cascade trunk for a multi-home room.
- **Clients:** always WebRTC to a nearby edge URL from `/place` -- never to
  "the Erlang node next door."

---

## Live migration (when an edge goes away)

Rooms move. Hubs die. Clients need a nudge.

```text
  1. Peer hub down / regional hub re-elects
           |
           v
  Migrate clears cohosts, disconnects local trunk
           |
           v
  Connected Control WS clients get  migrate.required
           |
           v
  Client: GET /place again  ->  ICE-restart offer to new edge_url
           |
           v
  Replacement hub up + trunk keys set
           |
           v
  Auto Trunk.reconnect_cohosts  (or call it by hand)
```

| Trigger | What happens |
| --- | --- |
| Peer hub down | `Migrate.on_peer_hub_down/1` -- drop cohosts, disconnect trunk, notify |
| Peer hub up | `Migrate.on_peer_hub_up/1` -- reconnect if trunk keys available |
| Local hub changed | `Migrate.on_hub_changed/2` -- notify when **this** node became hub |

Manual notify (lab / ops drill):

```bash
mix xylon.cluster.migrate TENANT SESSION --reason edge_down
mix xylon.cluster.migrate TENANT SESSION --reason hub_changed
```

Client contract: on `migrate.required`, call place again, then send an
**ICE-restart** offer to `target.edge_url`. Control Presence must be running for
the WS push; you can also `Migrate.subscribe/1` for mailbox events.

Without `:trunk_keys` or all four `XYLON_TRUNK_*` env vars, auto-reconnect after
peer hub up does not run -- call `Xylon.Cluster.Trunk.reconnect_cohosts/2`
yourself.

---

## Anti-patterns (please don't)

```text
  BAD: RTP inside :erpc / GenServer messages
  BAD: every SFU meshed to every SFU for media
  BAD: WebRTC/ICE as the first SFU-to-SFU transport
  BAD: treating libcluster as a media fabric
```

```text
  GOOD: clients <-> nearby edge over WebRTC
  GOOD: edge <-> edge media over XGW.Trunk.Pipe
  GOOD: control discovery + :erpc for setup and announce only
```

---

## Lab helpers (tests)

Default ExUnit excludes heavy tags. Opt in when you mean it:

```bash
# dual BEAM edges, same session key
mix test --include dual_node

# N-region hub election + trunk + migrate
mix test --include cluster
```

Programmatic lab (internal helper -- not the product clustering API):

| Helper | Use |
| --- | --- |
| `Xylon.Trunk.Lab.start_pair/0` | Two edges, one cookie, dual-node trunk |
| `Xylon.Trunk.Lab.start_hubs/1` | Two hubs, distinct `region_id`s |
| `Xylon.Trunk.Lab.start_extra_hub/2` | Bring another hub online (migrate drills) |

`connect_pair/3` on Manager is a **single-host** unit helper (two Sessions, one
BEAM). Multi-node uses `connect_remote/3` / `connect_hubs/3`.

---

## Mix task cheat sheet

```text
mix xylon.cluster.bootstrap          # print env + config sketch
mix xylon.cluster.status             # region, nodes, hub
mix xylon.place TENANT SESSION [--region R] [--multi-home]
mix xylon.trunk.connect TENANT SESSION PEER_NODE MODULE_ID
mix xylon.trunk.status TENANT SESSION
mix xylon.cluster.migrate TENANT SESSION [--reason edge_down|hub_changed]
```

---

## Config knobs

```elixir
config :xylon, :cluster,
  enabled: true,
  region_id: "us-west-2",
  hub_priority: 10,
  topologies: [],   # or libcluster topologies
  edge_urls: %{"us-west-2" => "https://media-us.example.com"},
  trunk_keys: [key_ab: ..., salt_ab: ..., key_ba: ..., salt_ba: ...]
```

| Env | Role |
| --- | --- |
| `XYLON_REGION_ID` | Region when config omits `:region_id` |
| `XYLON_HUB_PRIORITY` | Election weight default |
| `XYLON_TRUNK_KEY_AB` / `_SALT_AB` / `_KEY_BA` / `_SALT_BA` | Directional trunk keys |

---

## Honest limits (today)

- Placement sticky home picks the lexicographically smallest node name on first
  assign -- not load-aware balancing.
- `edge_url` in placement is only filled when `:edge_urls` maps that region.
- Auto trunk reconnect after peer hub recovery needs keys configured.
- `migrate.required` WS push needs Control Presence; otherwise use subscribe /
  Mix migrate.
- Lab helpers use `:peer` and often empty `topologies` -- production membership
  is your cookie + `libcluster` (or equivalent) story.

---

## RFCs

- [RFC 3711](https://www.rfc-editor.org/rfc/rfc3711) -- SRTP on the trunk pipe
- Control / cluster membership -- product APIs; no STUN/TURN media RFC
