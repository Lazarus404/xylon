defmodule Xylon.Ice do
  @moduledoc """
  ICE advertise address and gather options for sessions.

  ## What problem this solves

  Two peers on the internet rarely know each other's IP addresses upfront. **ICE**
  (Interactive Connectivity Establishment) discovers reachable UDP paths and picks
  one for media. Xylon answers as an ICE **lite** agent in most lab flows: it
  advertises host candidates from [XGW](https://github.com/Lazarus404/xgw)
  `Listener` using an IP browsers can actually reach.

  If you advertise every local interface, some browsers re-select a candidate after
  DTLS/SCTP comes up and datachannel data can stall. Set one public or LAN address
  (or an explicit list) via `config :xylon, :ice` or `XYLON_ADVERTISED_IP` /
  `XYLON_ADVERTISED_IPS` (comma-separated). Lab scripts often advertise
  `127.0.0.1` plus the primary LAN IP so Chrome host pairs have a working path.

  Example:

      config :xylon, :ice,
        advertised_ip: {203, 0, 113, 10},
        mode: :lite,
        stun_servers: ["stun.l.google.com:19302"]

  `mode: :full` enables full ICE and outbound trickle on the Control WebSocket.
  HTTP JSEP and SIP signaling stay ICE-lite. Lab Mix tasks call
  `ensure_configured!/0`, which loads `XYLON_ADVERTISED_IP` when config is unset.

  ## RFCs and related specs

  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- ICE
  - [RFC 8838](https://www.rfc-editor.org/rfc/rfc8838) -- ICE trickle (full mode)
  - STUN/TURN server URIs passed through to XGW Listener gather
  """

  @typedoc """
  IPv4 or IPv6 address tuple embedded in SDP host candidates.

  ## Fields

  Not a struct: a `:inet.ip_address()` tuple such as `{127, 0, 0, 1}`.
  """
  @type addr :: :inet.ip_address()

  @typedoc """
  ICE agent mode for Control WebSocket offers.

  ## Fields

  - `:lite` -- Server advertises host candidates; remote does connectivity checks.
  - `:full` -- Server runs full ICE and may trickle local candidates.
  """
  @type mode :: :lite | :full

  @doc """
  Returns keyword opts for `XGW.Listener.start_link/1` gather/advertise.

  Reads `:advertised_ip` or `:advertised_ips` from `config :xylon, :ice`.
  Raises `ArgumentError` when neither is set.
  """
  @spec listener_opts!() :: keyword()
  def listener_opts! do
    ice = ice_env()

    cond do
      match?([_ | _], Keyword.get(ice, :advertised_ips)) ->
        [advertised_ips: Keyword.fetch!(ice, :advertised_ips)]

      match?({_, _, _, _}, Keyword.get(ice, :advertised_ip)) or
          match?({_, _, _, _, _, _, _, _}, Keyword.get(ice, :advertised_ip)) ->
        [advertised_ip: Keyword.fetch!(ice, :advertised_ip)]

      true ->
        raise ArgumentError, """
        config :xylon, :ice must set :advertised_ip or :advertised_ips \
        (ICE-lite host candidates). Lab: XYLON_ADVERTISED_IP=127.0.0.1. \
        Production: the public or LAN address browsers reach.
        """
    end
  end

  @doc """
  Returns configured ICE mode (`:lite` default).

  Accepts atom or string `"lite"` / `"full"` from application env.
  """
  @spec mode() :: mode()
  def mode do
    case Keyword.get(ice_env(), :mode, :lite) do
      :full -> :full
      "full" -> :full
      :lite -> :lite
      "lite" -> :lite
      _ -> :lite
    end
  end

  @doc """
  Returns `true` when `mode/0` is `:full` (Control WS full ICE).
  """
  @spec full?() :: boolean()
  def full?, do: mode() == :full

  @doc """
  Optional STUN/TURN keys for `XGW.Listener.start_link/1`.

  Reads `:stun_servers` and `:turn_servers` from `config :xylon, :ice`.
  Omits keys when unset or empty.
  """
  @spec stun_listener_opts() :: keyword()
  def stun_listener_opts do
    ice = ice_env()

    []
    |> maybe_kw(:stun_servers, Keyword.get(ice, :stun_servers))
    |> maybe_kw(:turn_servers, Keyword.get(ice, :turn_servers))
  end

  @doc """
  Returns `true` when `:advertised_ip` or `:advertised_ips` is configured.
  """
  @spec configured?() :: boolean()
  def configured? do
    ice = ice_env()

    match?([_ | _], Keyword.get(ice, :advertised_ips)) or
      match?({_, _, _, _}, Keyword.get(ice, :advertised_ip)) or
      match?({_, _, _, _, _, _, _, _}, Keyword.get(ice, :advertised_ip))
  end

  @doc """
  Ensures `:ice` is configured, loading env when needed.

  Loads `XYLON_ADVERTISED_IPS` (comma-separated) when set, else
  `XYLON_ADVERTISED_IP` when advertise is missing. Always overlays
  `XYLON_ICE_MODE` and `XYLON_STUN_SERVERS` when those env vars are set.

  Raises `ArgumentError` if advertise is still unset or the IP env is invalid.
  """
  @spec ensure_configured!() :: :ok
  def ensure_configured! do
    apply_advertise_env!()

    if not configured?() do
      put_env!(System.get_env("XYLON_ADVERTISED_IP"))
    end

    apply_mode_env!()
    apply_stun_env!()
    :ok
  end

  @doc """
  Sets `config :xylon, :ice` advertise from an IP string, merging existing keys.

  Raises when `ip` is nil/empty or not parseable.
  """
  @spec put_env!(String.t() | nil) :: :ok
  def put_env!(ip) when is_binary(ip) and ip != "" do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} ->
        merge_ice!(advertised_ip: addr)
        :ok

      {:error, _} ->
        raise ArgumentError, "XYLON_ADVERTISED_IP must be an IP address, got: #{inspect(ip)}"
    end
  end

  def put_env!(_other) do
    raise ArgumentError,
          "XYLON_ADVERTISED_IP is required (e.g. 127.0.0.1 or your public host IP)"
  end

  @doc """
  Sets `:advertised_ips` from a comma-separated IP list (lab multi-homed advertise).

  Clears a conflicting single `:advertised_ip` so `listener_opts!/0` uses the list.
  """
  @spec put_ips_env!(String.t()) :: :ok
  def put_ips_env!(csv) when is_binary(csv) and csv != "" do
    ips =
      csv
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn ip ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, addr} ->
            addr

          {:error, _} ->
            raise ArgumentError, "XYLON_ADVERTISED_IPS entry must be an IP, got: #{inspect(ip)}"
        end
      end)

    if ips == [] do
      raise ArgumentError, "XYLON_ADVERTISED_IPS must list at least one IP"
    end

    ice =
      ice_env()
      |> Keyword.delete(:advertised_ip)
      |> Keyword.put(:advertised_ips, ips)

    Application.put_env(:xylon, :ice, ice)
    :ok
  end

  @doc "Human-readable advertise summary for lab banners."
  @spec summary() :: String.t()
  def summary do
    case listener_opts!() do
      [advertised_ip: addr] -> format_addr(addr)
      [advertised_ips: ips] -> Enum.map_join(ips, ", ", &format_addr/1)
    end
  end

  defp ice_env, do: Application.get_env(:xylon, :ice, [])

  defp merge_ice!(kw) when is_list(kw) do
    Application.put_env(:xylon, :ice, Keyword.merge(ice_env(), kw))
  end

  defp apply_advertise_env! do
    case System.get_env("XYLON_ADVERTISED_IPS") do
      csv when is_binary(csv) and csv != "" -> put_ips_env!(csv)
      _ -> :ok
    end
  end

  defp apply_mode_env! do
    case System.get_env("XYLON_ICE_MODE") do
      nil ->
        :ok

      "" ->
        :ok

      mode when mode in ["full", "lite"] ->
        merge_ice!(mode: String.to_existing_atom(mode))

      other ->
        raise ArgumentError, "XYLON_ICE_MODE must be full or lite, got: #{inspect(other)}"
    end
  end

  defp apply_stun_env! do
    case System.get_env("XYLON_STUN_SERVERS") do
      nil ->
        :ok

      "" ->
        :ok

      csv ->
        servers =
          csv
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&normalize_stun_uri/1)

        merge_ice!(stun_servers: servers)
    end
  end

  # XGW Gather.parse_stun_server/1 requires "stun:host:port".
  defp normalize_stun_uri(<<"stun:", _::binary>> = uri), do: uri
  defp normalize_stun_uri(<<"stuns:", _::binary>> = uri), do: uri
  defp normalize_stun_uri(host_port) when is_binary(host_port), do: "stun:" <> host_port

  defp maybe_kw(opts, _key, nil), do: opts
  defp maybe_kw(opts, _key, []), do: opts

  defp maybe_kw(opts, :stun_servers, value) when is_list(value) do
    Keyword.put(opts, :stun_servers, Enum.map(value, &normalize_stun_uri/1))
  end

  defp maybe_kw(opts, key, value) when is_list(value), do: Keyword.put(opts, key, value)

  defp format_addr(addr), do: addr |> :inet.ntoa() |> to_string()
end
