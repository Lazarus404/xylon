defmodule Xylon.Trunk.Lab.SinkPeer do
  @moduledoc """
  Minimal FakePeer for multi-home lab tests (RTP + datachannel drain).

  ## What problem this solves

  Dual-node cascade tests need a Peer-like GenServer on each edge that records
  `send_rtp` / `send_datachannel` without XGW. Available in the `:xylon` app so
  peer nodes can start it via `:erpc`.

  ## Internal

  Lab only.

  ## RFCs

  None.
  """

  use GenServer

  @doc "Starts a sink peer (unlinked; safe for `:erpc` on remote nodes)."
  @spec start() :: GenServer.on_start()
  def start, do: GenServer.start(__MODULE__, [])

  @doc "Starts a sink peer linked to the caller."
  @spec start_link() :: GenServer.on_start()
  def start_link, do: GenServer.start_link(__MODULE__, [])

  @doc "Returns and clears recorded send events."
  @spec drain(pid()) :: [tuple()]
  def drain(pid), do: GenServer.call(pid, :drain)

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_call({:send_rtp, ssrc, packet}, _from, state) do
    {:reply, :ok, [{:send_rtp, ssrc, packet} | state]}
  end

  def handle_call({:send_rtcp, packet}, _from, state) do
    {:reply, :ok, [{:send_rtcp, packet} | state]}
  end

  def handle_call({:send_datachannel, ref, data, type}, _from, state) do
    {:reply, :ok, [{:send_datachannel, ref, data, type} | state]}
  end

  def handle_call({:send_datachannel, ref, data}, _from, state) do
    handle_call({:send_datachannel, ref, data, :string}, nil, state)
  end

  def handle_call(:drain, _from, state), do: {:reply, Enum.reverse(state), []}

  @impl true
  def handle_cast({:send_rtp, ssrc, packet}, state) do
    {:noreply, [{:send_rtp, ssrc, packet} | state]}
  end

  def handle_cast({:send_rtcp, packet}, state) do
    {:noreply, [{:send_rtcp, packet} | state]}
  end

  def handle_cast({:send_datachannel, ref, data, type}, state) do
    {:noreply, [{:send_datachannel, ref, data, type} | state]}
  end

  def handle_cast({:send_datachannel, ref, data}, state) do
    handle_cast({:send_datachannel, ref, data, :string}, state)
  end
end
