defmodule Xylon.Trunk.Bridge do
  @moduledoc """
  Relays inbound trunk pipe media into a session Forwarder.

  ## What problem this solves

  `XGW.Trunk.Pipe` delivers decrypted RTP/RTCP/DC to a handler pid. The local
  SFU still expects `{:xgw, :rtp, peer, packet, meta}` on the Forwarder. This
  bridge maps pipe inbound messages onto that contract, using the pipe pid as
  the peer so Plans can treat the trunk as a publisher or DC member.

  ## RFCs

  * RFC 3550 -- RTP after unprotect
  """

  use GenServer

  alias XGW.Trunk.Pipe

  @doc """
  Starts a bridge that injects into `forwarder`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Points `pipe` inbound delivery at this bridge.
  """
  @spec attach_pipe(pid(), pid()) :: :ok
  def attach_pipe(bridge, pipe) when is_pid(bridge) and is_pid(pipe) do
    GenServer.call(bridge, {:attach_pipe, pipe})
  end

  @impl true
  def init(opts) do
    forwarder = Keyword.fetch!(opts, :forwarder)
    {:ok, %{forwarder: forwarder, pipes: MapSet.new()}}
  end

  @impl true
  def handle_call({:attach_pipe, pipe}, _from, state) do
    :ok = Pipe.set_handler(pipe, self())
    {:reply, :ok, %{state | pipes: MapSet.put(state.pipes, pipe)}}
  end

  @impl true
  def handle_info({Pipe, :rtp, pipe, _ssrc, rtp}, state) do
    if MapSet.member?(state.pipes, pipe) do
      send(state.forwarder, {:xgw, :rtp, pipe, rtp, %{trunk: true}})
    end

    {:noreply, state}
  end

  def handle_info({Pipe, :rtcp, pipe, rtcp}, state) do
    if MapSet.member?(state.pipes, pipe) do
      send(state.forwarder, {:xgw, :rtcp, pipe, rtcp, %{trunk: true}})
    end

    {:noreply, state}
  end

  def handle_info({Pipe, :dc, pipe, label, data}, state) do
    if MapSet.member?(state.pipes, pipe) do
      case Pipe.ensure_label(pipe, label) do
        {:ok, channel_ref} ->
          send(state.forwarder, {:xgw, :datachannel_message, pipe, channel_ref, data})

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
