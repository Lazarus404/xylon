defmodule Xylon.Participant do
  @moduledoc """
  One connected client inside a session.

  ## What problem this solves

  Each person or device in a call needs its own encrypted transport to the
  server. Xylon tracks that endpoint as a **participant**: a stable id, the
  [XGW](https://github.com/Lazarus404/xgw) Peer that terminates DTLS-SRTP, the
  Listener that gathered ICE candidates, and optional metadata for signaling
  and control.

  Backends receive `%Xylon.Participant{}` on join/leave and on every RTP/RTCP/
  datachannel callback routed through `Xylon.Forwarder`.

  ## RFCs and related specs

  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- ICE (Listener + Peer)
  - [RFC 5764](https://www.rfc-editor.org/rfc/rfc5764) -- DTLS-SRTP (Peer)
  """

  @typedoc """
  One session member and its XGW processes.

  ## Fields

  - `:id` - Application-chosen participant id (string or term from signaling).
  - `:peer_ref` - `XGW.Peer` pid for this connection; `nil` before offer applied.
  - `:listener` - `XGW.Listener` pid that owns the UDP port and host candidates.
  - `:role` - Backend hint: `:echo`, `:publisher`, `:subscriber`, `:trunk`, or custom atom.
  - `:meta` - Extensible map. Common keys:
    - `:signaling_pid` / `:signaling_ref` -- Control WebSocket for outbound ICE
    - `:ice_lite?` -- whether this Peer was started in ICE-lite mode
    - `:pending_control_ice` -- buffered ICE events before WS bind
  """
  @type t :: %__MODULE__{
          id: term(),
          peer_ref: pid() | nil,
          listener: pid() | nil,
          role: :publisher | :subscriber | :echo | :trunk | atom(),
          meta: map()
        }

  defstruct id: nil, peer_ref: nil, listener: nil, role: :echo, meta: %{}
end
