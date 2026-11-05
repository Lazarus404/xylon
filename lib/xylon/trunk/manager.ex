defmodule Xylon.Trunk.Manager do
  @moduledoc """
  OTP lifecycle for inter-edge media trunks (control plane only).

  ## What problem this solves

  Multi-home rooms need to create, pair, and tear down `XGW.Trunk.Pipe`
  endpoints and install them as `:trunk` participants on local Sessions.
  Media bytes stay on UDP+SRTP; this GenServer owns lifecycle, Bridge wiring,
  and control announces (`:erpc` only -- never media payloads).

  ## RFCs

  None for control; pipe media uses RFC 3711 via `XGW.Trunk.Pipe`.
  """

  use GenServer

  alias XGW.Trunk.Pipe
  alias Xylon.Session
  alias Xylon.Trunk.{Announce, Bridge, Participant}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a local trunk pipe, publishes SendHandles, and attaches it to `session`.

  Opts: `:id`, `:master_key`, `:master_salt`, or directional write keys;
  `:handler` (default Bridge when Forwarder exists).
  """
  @spec connect(pid(), keyword()) :: {:ok, Xylon.Participant.t()} | {:error, term()}
  def connect(session, opts) when is_pid(session) and is_list(opts) do
    GenServer.call(__MODULE__, {:connect, session, opts})
  end

  @doc """
  Removes a trunk participant and closes its pipe.
  """
  @spec disconnect(pid(), term()) :: :ok | {:error, term()}
  def disconnect(session, trunk_id) when is_pid(session) do
    GenServer.call(__MODULE__, {:disconnect, session, trunk_id})
  end

  @doc """
  Connects two local sessions with a paired UDP trunk (single-host unit tests).
  """
  @spec connect_pair(pid(), pid(), keyword()) ::
          {:ok, %{a: Xylon.Participant.t(), b: Xylon.Participant.t()}} | {:error, term()}
  def connect_pair(session_a, session_b, opts)
      when is_pid(session_a) and is_pid(session_b) and is_list(opts) do
    GenServer.call(__MODULE__, {:connect_pair, session_a, session_b, opts})
  end

  @doc """
  Pairs this session's trunk with a Manager on `remote_node` (control via `:erpc`).

  Opts:

  * `:session_key` - `{tenant_id, session_id}` (must match remote)
  * `:module_id` - catalogue backend on remote if Session must be created
  * `:key_ab` / `:salt_ab` / `:key_ba` / `:salt_ba` - directional write keys
  * `:master_key` / `:master_salt` - lab shared alias
  * `:trunk_id` - local trunk participant id (default `"trunk"`)
  * `:remote_trunk_id` - far trunk id (default `"trunk"`)
  * `:backend_opts` - Session.create opts on remote when creating
  """
  @spec connect_remote(pid(), node(), keyword()) ::
          {:ok, Xylon.Participant.t()} | {:error, term()}
  def connect_remote(session, remote_node, opts)
      when is_pid(session) and is_atom(remote_node) and is_list(opts) do
    GenServer.call(__MODULE__, {:connect_remote, session, remote_node, opts}, 30_000)
  end

  @doc false
  @spec accept_remote(keyword()) ::
          {:ok, %{addr: tuple(), participant: Xylon.Participant.t()}} | {:error, term()}
  def accept_remote(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:accept_remote, opts}, 30_000)
  end

  @doc """
  Applies a control-plane track/participant announcement to `session`.
  """
  @spec announce_tracks(pid(), map()) :: :ok | {:error, term()}
  def announce_tracks(session, announcement) when is_pid(session) and is_map(announcement) do
    GenServer.call(__MODULE__, {:announce_tracks, session, announcement})
  end

  @doc """
  Sends an announcement to a Manager on `remote_node` (Erlang dist control only).
  """
  @spec announce_tracks_remote(node(), pid() | {term(), term()}, map()) ::
          :ok | {:error, term()}
  def announce_tracks_remote(remote_node, session_or_key, announcement)
      when is_atom(remote_node) and is_map(announcement) do
    :erpc.call(remote_node, __MODULE__, :announce_tracks_local, [session_or_key, announcement])
  end

  @doc false
  def announce_tracks_local(session, announcement) when is_pid(session) do
    announce_tracks(session, announcement)
  end

  def announce_tracks_local({tenant_id, session_id}, announcement) do
    case Registry.lookup(Xylon.Registry, {tenant_id, session_id}) do
      [{pid, _}] -> announce_tracks(pid, announcement)
      [] -> {:error, :session_not_found}
    end
  end

  @doc """
  Looks up the trunk pipe pid for a session (lab / hooks).
  """
  @spec trunk_pipe(pid(), term()) :: pid() | nil
  def trunk_pipe(session, trunk_id \\ "trunk") when is_pid(session) do
    GenServer.call(__MODULE__, {:trunk_pipe, session, trunk_id})
  end

  @doc """
  Builds an announcement from `payload` and sends it to `remote_node` (control).

  `payload` keys: `:from_edge`, `:participants`, `:tracks`, `:trunk_id`.
  """
  @spec announce_local_change(node(), {term(), term()}, map()) :: :ok | {:error, term()}
  def announce_local_change(remote_node, session_key, payload)
      when is_atom(remote_node) and is_tuple(session_key) and is_map(payload) do
    announcement =
      Announce.new(
        session_key: session_key,
        from_edge: Map.get(payload, :from_edge, Node.self()),
        participants: Map.get(payload, :participants, []),
        tracks: Map.get(payload, :tracks, [])
      )
      |> Map.put(:trunk_id, Map.get(payload, :trunk_id, "trunk"))

    announce_tracks_remote(remote_node, session_key, announcement)
  end

  @impl true
  def init(_opts) do
    {:ok, %{trunks: %{}}}
  end

  @impl true
  def handle_call({:connect, session, opts}, _from, state) do
    case do_connect(session, opts, state) do
      {:ok, participant, state2} -> {:reply, {:ok, participant}, state2}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disconnect, session, trunk_id}, _from, state) do
    key = {session, trunk_id}

    case Map.pop(state.trunks, key) do
      {nil, _} ->
        _ = Session.leave_participant(session, trunk_id, stop_if_empty: false)
        {:reply, :ok, state}

      {%{pipe: pipe, bridge: bridge}, trunks} ->
        _ = Session.leave_participant(session, trunk_id, stop_if_empty: false)
        stop_pid(bridge)
        stop_pid(pipe)
        {:reply, :ok, %{state | trunks: trunks}}

      {%{pipe: pipe}, trunks} ->
        _ = Session.leave_participant(session, trunk_id, stop_if_empty: false)
        stop_pid(pipe)
        {:reply, :ok, %{state | trunks: trunks}}
    end
  end

  def handle_call({:connect_pair, session_a, session_b, opts}, _from, state) do
    id_a = Keyword.get(opts, :id_a, "trunk_ab")
    id_b = Keyword.get(opts, :id_b, "trunk_ba")
    {opts_a, opts_b} = pair_key_opts(opts)

    with :ok <- agree_cascade_profiles(session_a, session_b),
         {:ok, pa, state1} <- do_connect(session_a, Keyword.put(opts_a, :id, id_a), state),
         {:ok, pb, state2} <- do_connect(session_b, Keyword.put(opts_b, :id, id_b), state1),
         {:ok, {ip_a, port_a}} <- Pipe.local_addr(pa.peer_ref),
         {:ok, {ip_b, port_b}} <- Pipe.local_addr(pb.peer_ref),
         :ok <- Pipe.connect(pa.peer_ref, ip_b, port_b),
         :ok <- Pipe.connect(pb.peer_ref, ip_a, port_a) do
      {:reply, {:ok, %{a: pa, b: pb}}, state2, {:continue, {:mcu_mix_pair, session_a, session_b}}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      other -> {:reply, {:error, other}, state}
    end
  end

  def handle_call({:connect_remote, session, remote_node, opts}, _from, state) do
    session_key = Keyword.fetch!(opts, :session_key)
    module_id = Keyword.fetch!(opts, :module_id)
    trunk_id = Keyword.get(opts, :trunk_id, "trunk")
    remote_trunk_id = Keyword.get(opts, :remote_trunk_id, "trunk")
    backend_opts = Keyword.get(opts, :backend_opts, [])
    {opts_a, opts_b} = pair_key_opts(opts)

    with :ok <- agree_cascade_backend_opts(session, backend_opts),
         {:ok, pa, state1} <-
           do_connect(session, Keyword.merge(opts_a, id: trunk_id), state),
         {:ok, {ip_a, port_a}} <- Pipe.local_addr(pa.peer_ref),
         {:ok, %{addr: {ip_b, port_b}}} <-
           :erpc.call(remote_node, __MODULE__, :accept_remote, [
             [
               session_key: session_key,
               module_id: module_id,
               trunk_id: remote_trunk_id,
               peer_addr: {ip_a, port_a},
               backend_opts: backend_opts
             ] ++ opts_b
           ]),
         :ok <- Pipe.connect(pa.peer_ref, ip_b, port_b) do
      {:reply, {:ok, pa}, state1,
       {:continue, {:mcu_mix_remote, session, remote_node, session_key, backend_opts}}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:badrpc, reason} -> {:reply, {:error, {:badrpc, reason}}, state}
      other -> {:reply, {:error, other}, state}
    end
  end

  def handle_call({:accept_remote, opts}, _from, state) do
    {tenant_id, session_id} = Keyword.fetch!(opts, :session_key)
    module_id = Keyword.fetch!(opts, :module_id)
    trunk_id = Keyword.get(opts, :trunk_id, "trunk")
    {ip_a, port_a} = Keyword.fetch!(opts, :peer_addr)
    backend_opts = Keyword.get(opts, :backend_opts, [])

    with {:ok, session} <- ensure_session(tenant_id, session_id, module_id, backend_opts),
         {:ok, pb, state1} <- do_connect(session, Keyword.put(opts, :id, trunk_id), state),
         :ok <- Pipe.connect(pb.peer_ref, ip_a, port_a),
         {:ok, addr} <- Pipe.local_addr(pb.peer_ref) do
      {:reply, {:ok, %{addr: addr, participant: pb, session: session}}, state1}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      other -> {:reply, {:error, other}, state}
    end
  end

  def handle_call({:announce_tracks, session, announcement}, _from, state) do
    case apply_announcement(session, announcement, state) do
      :ok -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:trunk_pipe, session, trunk_id}, _from, state) do
    {:reply, trunk_pipe_from_state(state, session, trunk_id), state}
  end

  @impl true
  def handle_continue({:mcu_mix_pair, session_a, session_b}, state) do
    _ = maybe_announce_mcu_mix_pair(session_a, session_b, state)
    {:noreply, state}
  end

  def handle_continue({:mcu_mix_remote, session, remote_node, session_key}, state) do
    _ = maybe_announce_mcu_mix_remote(session, remote_node, session_key, [])
    {:noreply, state}
  end

  def handle_continue({:mcu_mix_remote, session, remote_node, session_key, backend_opts}, state) do
    _ = maybe_announce_mcu_mix_remote(session, remote_node, session_key, backend_opts)
    {:noreply, state}
  end

  defp agree_cascade_profiles(session_a, session_b) do
    if Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) do
      apply(Xylon.Conference.Mcu.Cascade, :agree_session_profiles, [session_a, session_b])
    else
      :ok
    end
  end

  defp agree_cascade_backend_opts(session, backend_opts) do
    if Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) do
      apply(Xylon.Conference.Mcu.Cascade, :agree_hub_backend_opts, [session, backend_opts])
    else
      :ok
    end
  end

  defp apply_announcement(session, announcement, state) do
    if Announce.valid?(announcement) do
      trunk_id = Map.get(announcement, :trunk_id, "trunk")
      trunk_pipe = trunk_pipe_from_state(state, session, trunk_id)

      results =
        Enum.map(announcement.participants, fn p ->
          id = Map.fetch!(p, :id)
          role = Map.get(p, :role, :publisher)
          labels = Map.get(p, :labels, [])

          tracks =
            Enum.filter(announcement.tracks, fn t -> Map.get(t, :publisher_id) == id end)

          participant = %Xylon.Participant{
            id: id,
            peer_ref: trunk_pipe,
            listener: nil,
            role: role,
            meta: %{
              remote: true,
              from_edge: announcement.from_edge,
              labels: labels,
              tracks: tracks
            }
          }

          case Session.attach_participant(session, participant) do
            :ok ->
              Xylon.Trunk.Hooks.apply_announce(session, participant, announcement)

            {:error, :participant_exists} ->
              Xylon.Trunk.Hooks.apply_announce(session, participant, announcement)

            other ->
              other
          end
        end)

      if Enum.all?(results, &(&1 == :ok)) do
        :ok
      else
        case Enum.find(results, &match?({:error, :mcu_cascade_profile_mismatch}, &1)) do
          {:error, _} = err -> err
          _ -> {:error, {:announce_partial, results}}
        end
      end
    else
      {:error, :invalid_announce}
    end
  end

  defp do_connect(session, opts, state) do
    id = Keyword.get(opts, :id, "trunk1")
    pipe_opts = pipe_key_opts(opts)

    fwd = Session.forwarder(session)

    with {:ok, bridge} <- maybe_start_bridge(fwd),
         handler <- bridge || Keyword.get(opts, :handler, self()),
         {:ok, pipe} <- Pipe.start_link([handler: handler] ++ pipe_opts),
         :ok <- maybe_attach_bridge(bridge, pipe),
         :ok <- Pipe.publish_send_handles(pipe) do
      participant = Participant.build(id, pipe)

      case Session.attach_participant(session, participant) do
        :ok ->
          entry = %{pipe: pipe, participant: participant, bridge: bridge}

          state = put_in(state, [:trunks, {session, id}], entry)
          {:ok, participant, state}

        {:error, :participant_exists} ->
          # Reuse existing trunk attach for reconnect labs.
          stop_pid(pipe)
          stop_pid(bridge)
          existing = get_in(state, [:trunks, {session, id}])

          if existing do
            {:ok, existing.participant, state}
          else
            {:error, :participant_exists}
          end

        {:error, reason} ->
          stop_pid(pipe)
          stop_pid(bridge)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp maybe_start_bridge(fwd) when is_pid(fwd) do
    Bridge.start_link(forwarder: fwd)
  end

  defp maybe_start_bridge(_), do: {:ok, nil}

  defp maybe_attach_bridge(nil, _pipe), do: :ok
  defp maybe_attach_bridge(bridge, pipe), do: Bridge.attach_pipe(bridge, pipe)

  defp ensure_session(tenant_id, session_id, module_id, backend_opts) do
    case Registry.lookup(Xylon.Registry, {tenant_id, session_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        Session.create(tenant_id, session_id, module_id, backend_opts)
    end
  end

  defp trunk_pipe_from_state(state, session, trunk_id) do
    case Map.get(state.trunks, {session, trunk_id}) do
      %{pipe: pipe} -> pipe
      _ -> nil
    end
  end

  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  defp stop_pid(_), do: :ok

  defp maybe_announce_mcu_mix_pair(session_a, session_b, state) do
    if Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) do
      cascade = Xylon.Conference.Mcu.Cascade

      with :ok <- apply(cascade, :agree_session_profiles, [session_a, session_b]) do
        cond do
          apply(cascade, :hub_session?, [session_a]) and
              not apply(cascade, :hub_session?, [session_b]) ->
            announce_hub_mix_inline(session_a, session_b, state)

          apply(cascade, :hub_session?, [session_b]) and
              not apply(cascade, :hub_session?, [session_a]) ->
            announce_hub_mix_inline(session_b, session_a, state)

          true ->
            :ok
        end
      end
    else
      :ok
    end
  end

  defp announce_hub_mix_inline(hub_session, spoke_session, state) do
    cascade = Xylon.Conference.Mcu.Cascade
    hub_state = :sys.get_state(hub_session).backend_state
    spoke_state = :sys.get_state(spoke_session).backend_state

    with :ok <-
           apply(cascade, :agree_trunk_profile, [
             Map.get(hub_state, :mcu_cascade_trunk_profile),
             Map.get(spoke_state, :mcu_cascade_trunk_profile)
           ]),
         {:ok, ann} <- apply(cascade, :mix_announce, [hub_state.plan_ref, hub_state, []]) do
      apply_announcement(spoke_session, ann, state)
    end
  end

  defp maybe_announce_mcu_mix_remote(session, remote_node, session_key, backend_opts) do
    if Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) do
      opts =
        case Keyword.fetch(List.wrap(backend_opts), :mcu_cascade_trunk_profile) do
          {:ok, profile} -> [spoke_trunk_profile: profile]
          :error -> []
        end

      apply(Xylon.Conference.Mcu.Cascade, :maybe_announce_after_remote, [
        session,
        remote_node,
        session_key,
        opts
      ])
    else
      :ok
    end
  end

  defp pipe_key_opts(opts) do
    case Keyword.fetch(opts, :local_write_key) do
      {:ok, _} ->
        Keyword.take(opts, [
          :local_write_key,
          :local_write_salt,
          :remote_write_key,
          :remote_write_salt
        ])

      :error ->
        [
          master_key: Keyword.fetch!(opts, :master_key),
          master_salt: Keyword.fetch!(opts, :master_salt)
        ]
    end
  end

  defp pair_key_opts(opts) do
    case Keyword.fetch(opts, :key_ab) do
      {:ok, key_ab} ->
        salt_ab = Keyword.fetch!(opts, :salt_ab)
        key_ba = Keyword.fetch!(opts, :key_ba)
        salt_ba = Keyword.fetch!(opts, :salt_ba)

        opts_a = [
          local_write_key: key_ab,
          local_write_salt: salt_ab,
          remote_write_key: key_ba,
          remote_write_salt: salt_ba
        ]

        opts_b = [
          local_write_key: key_ba,
          local_write_salt: salt_ba,
          remote_write_key: key_ab,
          remote_write_salt: salt_ab
        ]

        {opts_a, opts_b}

      :error ->
        master_key = Keyword.fetch!(opts, :master_key)
        master_salt = Keyword.fetch!(opts, :master_salt)
        shared = [master_key: master_key, master_salt: master_salt]
        {shared, shared}
    end
  end
end
