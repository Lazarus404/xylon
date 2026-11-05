defmodule Xylon.Control do
  @moduledoc """
  Optional SaaS-shaped control plane for Xylon.

  ## What problem this solves

  Media backends handle fanout; operators still need tenant auth, server-side
  inject, ACL, presence, quotas, moderation, webhooks, and optional gRPC host
  APIs at the edge. Control authenticates requests, resolves inject targets,
  enforces policy, and emits events without owning RTP/RTCP forwarding.

  Enable with `config :xylon, control: [enabled: true, ...]`.

  Layout under `lib/xylon/control/`:

      auth.ex + auth/          Auth, Auth.HMAC, Auth.JWT
      secrets.ex + secrets/    Secrets, Record, Config, Local
      webhooks.ex + webhooks/  Webhooks, Delivery, Queue (DETS DLQ)
      context.ex               Authenticated Context struct
      router.ex, inject.ex, dest.ex
      membership.ex, presence.ex, feeds.ex, history.ex
      acl.ex, quota.ex, moderation.ex, audit.ex
      grpc/                   Optional Inject/Presence/History (grpc_port)
      v1/                    Generated Control protos

  Live session list: `GET /v1/tenants/:tid/sessions` (capability `"sessions"`).
  Fleet: `GET /v1/tenants/:tid/fleet/summary` and `.../fleet/nodes`, plus
  `POST .../fleet/accepting` to set per-node drain (capability `"fleet"`).
  Lifecycle webhooks: `session.created` / `session.closed` /
  `participant.joined` / `participant.left` (with `node` + `region`).

  ## RFCs

  - [RFC 7519](https://www.rfc-editor.org/rfc/rfc7519) -- JWT auth mode
  - [RFC 7517](https://www.rfc-editor.org/rfc/rfc7517) -- JWKS fetch (JWT mode)
  - Control HTTP/gRPC -- no STUN/TURN/SIP media RFC
  """
end
