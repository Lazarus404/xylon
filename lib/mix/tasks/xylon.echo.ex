defmodule Mix.Tasks.Xylon.Echo do
  @moduledoc """
  Start a local Xylon lab with Echo, HTTP JSEP, and SIP-over-WebSocket.

  ## What problem this solves

  You need a one-command way to try real-time media without deploying a cluster.
  This task boots the `:xylon` application with the Echo backend (media loopback),
  an HTTP port for browser JSEP signaling and a bundled test client, and SIP
  over WebSocket for softphone experiments.

      XYLON_ADVERTISED_IP=127.0.0.1 mix xylon.echo --http-port 8080

  - HTTP UI: `http://127.0.0.1:8080/` and `/client/`
  - SIP WebSocket: `ws://127.0.0.1:8080/sip` (subprotocol `sip`)
  - Default AOR: `sip:echo@127.0.0.1`
  - Lab tenant: `lab` (SIP) or `x-tenant-id` header (HTTP JSEP)

  Requires `XYLON_ADVERTISED_IP` or `config :xylon, :ice` for ICE host candidates
  (see `Xylon.Ice`). Optional `XYLON_ICE_MODE` and `XYLON_STUN_SERVERS`.

  Dependencies: [XGW](https://github.com/Lazarus404/xgw),
  [XSDP](https://github.com/Lazarus404/xsdp),
  [xsip](https://github.com/Lazarus404/xsip) for SIP stack integration.

  ## RFCs and related specs

  - W3C/IETF **JSEP** -- HTTP offer/answer on the lab port
  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP registration and INVITE
  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP (via XSDP)
  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- ICE (via `Xylon.Ice` + XGW)
  """
  use Mix.Task

  @shortdoc "Run Xylon Echo lab (HTTP + SIP WS)"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [http_port: :integer],
        aliases: [h: :http_port]
      )

    port = Keyword.get(opts, :http_port, 8080)
    Application.put_env(:xylon, :http_port, port)
    Application.put_env(:xylon, :sip_enabled, true)

    require_ice!()

    Mix.Task.run("app.start")

    Mix.shell().info("""
    xylon echo running
      HTTP  http://127.0.0.1:#{port}/
      Client http://127.0.0.1:#{port}/client/
      SIP   ws://127.0.0.1:#{port}/sip  (subprotocol sip)
      AOR   sip:echo@127.0.0.1
      ICE   mode=#{Xylon.Ice.mode()} advertise #{Xylon.Ice.summary()}
      default backend #{inspect(Xylon.default_backend())}
    Lab tenant id: lab (SIP) / x-tenant-id header (HTTP JSEP).
    Ctrl+C to stop.
    """)

    Process.sleep(:infinity)
  end

  defp require_ice! do
    Xylon.Ice.ensure_configured!()
  rescue
    e in ArgumentError -> Mix.raise(Exception.message(e))
  end
end
