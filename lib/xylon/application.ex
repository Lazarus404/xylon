defmodule Xylon.Application do
  @moduledoc """
  OTP application supervisor for the Xylon runtime.

  ## What problem this solves

  Real-time media needs long-lived processes: a registry to find sessions by
  tenant and id, a supervisor to start and stop them safely, shared ETS tables
  for backend lookup and RTP forwarding plans, and optional HTTP/SIP listeners
  so browsers and softphones can connect. This module wires those children
  together from `config :xylon` at boot.

  **Internal:** started by the `:xylon` application callback; not part of the
  public integration API. Use `Mix.Tasks.Xylon.Echo` for a lab boot or add
  `:xylon` to your release applications.

  ## Children (when enabled)

  - `Xylon.Catalogue` ETS and configured `Xylon.attach/1` backends
  - `Xylon.Forwarder` plan table
  - `Registry` (`Xylon.Registry`) and `DynamicSupervisor` (`Xylon.SessionSupervisor`)
  - `Xylon.Trunk.Manager` for inter-edge trunk lifecycle
  - `Xylon.Recording.Aggregator` for multi-home segment webhook merge
  - `Xylon.Cluster` children when `:cluster, enabled: true` (`libcluster` + hub)
  - Control plane GenServers when `:control, enabled: true`
  - SIP registrar/bindings when `:sip_enabled` or `:http_port` is set
  - Bandit HTTP on `:http_port` for JSEP and SIP WebSocket
  - gRPC control endpoint when `:control, grpc_port` is set

  ## RFCs and related specs

  Signaling children implement lab paths for JSEP over HTTP and
  [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) /
  [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) SIP-over-WebSocket.
  Media termination remains in [XGW](https://github.com/Lazarus404/xgw).
  """
  use Application

  @impl true
  def start(_type, _args) do
    :ok = Xylon.Catalogue.init()
    :ok = Xylon.Forwarder.ensure_table!()
    :ok = Xylon.Recording.Registry.ensure_table!()
    :ok = Xylon.Recording.LayoutSink.ensure_table!()
    :ok = Xylon.Cluster.Presence.init!()
    :ok = Xylon.Cluster.Accepting.init!()
    :ok = maybe_init_datachannel_plan()
    :ok = attach_configured_backends()

    if sip_enabled?() do
      Application.put_env(:xsip, :app, Xylon.Signaling.SIPApp)
    end

    children =
      [
        {Registry, keys: :unique, name: Xylon.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Xylon.SessionSupervisor},
        Xylon.Trunk.Manager,
        Xylon.Recording.Aggregator
      ] ++
        Xylon.Profile.children() ++
        Xylon.Cluster.children() ++
        control_children() ++ sip_children() ++ http_child() ++ grpc_child()

    Supervisor.start_link(children, strategy: :one_for_one, name: Xylon.Supervisor)
  end

  defp control_children do
    if Keyword.get(Application.get_env(:xylon, :control, []), :enabled, false) do
      [
        Xylon.Control.Membership,
        Xylon.Control.Groups,
        Xylon.Control.Presence,
        Xylon.Control.Feeds,
        Xylon.Control.Quota,
        Xylon.Control.Moderation,
        Xylon.Control.Audit,
        Xylon.Control.History,
        Xylon.Control.Webhooks.Queue
      ]
    else
      []
    end
  end

  defp grpc_child do
    control = Application.get_env(:xylon, :control, [])

    with true <- Keyword.get(control, :enabled, false) == true,
         port when is_integer(port) and port > 0 <- Keyword.get(control, :grpc_port) do
      [
        {GRPC.Server.Supervisor,
         endpoint: Xylon.Control.Grpc.Endpoint, port: port, start_server: true}
      ]
    else
      _ -> []
    end
  end

  defp attach_configured_backends do
    backends = Application.get_env(:xylon, :backends, [Xylon.Backend.Echo])

    Enum.each(backends, fn module ->
      case Xylon.attach(module) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "Xylon.attach(#{inspect(module)}) failed: #{inspect(reason)}"
      end
    end)

    default = Xylon.default_backend()

    unless Xylon.attached?(default) do
      raise "config :xylon, :default_backend (#{inspect(default)}) is not in the catalogue; attach it via :backends"
    end

    :ok
  end

  defp maybe_init_datachannel_plan do
    plan = Module.concat([Xylon, Datachannel, Plan])

    if Code.ensure_loaded?(plan) and function_exported?(plan, :init, 0) do
      apply(plan, :init, [])
    else
      :ok
    end
  end

  defp sip_enabled? do
    Application.get_env(:xylon, :sip_enabled, false) or
      match?(port when is_integer(port) and port > 0, Application.get_env(:xylon, :http_port))
  end

  defp sip_children do
    if sip_enabled?() do
      [
        Xylon.Signaling.SIP.Registrar,
        Xylon.Signaling.SIP.ConnRegistry,
        Xylon.Signaling.SIP.SessionBind
      ]
    else
      []
    end
  end

  defp http_child do
    case Application.get_env(:xylon, :http_port) do
      port when is_integer(port) and port > 0 ->
        [
          {Bandit,
           plug: Xylon.Signaling.HTTP,
           scheme: :http,
           port: port,
           ip: {0, 0, 0, 0}}
        ]

      _ ->
        []
    end
  end
end
