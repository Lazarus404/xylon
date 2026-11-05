defmodule Xylon.Signaling.SIPAdapter do
  @moduledoc """
  Documentation anchor for the SIP signaling integration surface.

  ## What problem this solves

  SIP signaling spans several modules (WebSocket handler, transport, registrar,
  session binding). This empty module names the integration boundary so docs
  and dependency graphs can point at a single module without pulling in XSIP
  types at compile time.

  **Runtime path:** `Xylon.Signaling.SIPApp` (`XSIP.App`) plus RFC 7118 modules
  under `Xylon.Signaling.SIP.*`. All media operations go through
  `Xylon.Signaling`; push or other transports can share the same facade later.

  ## RFCs and related specs

  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP (via [XSIP](https://github.com/Lazarus404/xsip))
  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP offer/answer (via [XSDP](https://github.com/Lazarus404/xsdp))
  """
end
