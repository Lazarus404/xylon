defmodule Xylon.Backend.Echo do
  @moduledoc """
  Lab backend that loops media back to the same participant.

  ## What problem this solves

  Before building a conference SFU or recorder, you need a minimal path to prove
  that signaling, ICE, DTLS, and codecs work end-to-end. **Echo** sends every
  audio/video RTP packet and datachannel message back to whoever sent it, so a
  browser can hear itself and verify latency without a second client.

  Delivery runs in `Xylon.Forwarder` (Peer `handler:`), not the Session mailbox.
  This module only defines rewrite policy: map inbound SSRCs to distinct outbound
  SSRCs (browsers break if send and receive share an SSRC) and strip RTP header
  extensions that would make echoed packets look late (abs-send-time, transport-cc).

  Default catalogue id is `:echo` (`id/0`). Attached automatically when listed in
  `config :xylon, :backends`.

  ## RFCs and related specs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) -- RTP rewritten on echo
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- codecs from XSDP offer
  - Media path via [XGW](https://github.com/Lazarus404/xgw) after DTLS-SRTP
  """

  @behaviour Xylon.Backend

  alias XMediaLib.Rtp

  @doc "Catalogue id for `Xylon.attach/1`."
  @spec id() :: :echo
  def id, do: :echo

  @impl true
  def init(_session, _opts), do: {:ok, %{ssrc_map: %{}}}

  @impl true
  def participant_joined(_participant, state), do: {:ok, state}

  @impl true
  def participant_left(_participant, state), do: {:ok, state}

  @doc "Echo Forwarder plan: loop media back to the same participant."
  @impl true
  @spec forward_plan(Xylon.Participant.t(), map()) :: {:ok, map(), map()}
  def forward_plan(participant, state) do
    {:ok, %{mode: :echo, participant: participant}, state}
  end

  @impl true
  def handle_rtp(participant, rtp, state) do
    in_ssrc = rtp_ssrc(rtp)
    {out_ssrc, state} = map_ssrc(state, in_ssrc)
    {:forward, [{participant, prepare_echo_rtp(rtp, out_ssrc)}], state}
  end

  @impl true
  def handle_rtcp(_participant, _rtcp, state), do: {:ok, state}

  @impl true
  def handle_datachannel(participant, channel_ref, data, state) do
    {:forward_dc, [{participant, channel_ref, data}], state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp map_ssrc(%{ssrc_map: map} = state, in_ssrc) when is_integer(in_ssrc) do
    case Map.fetch(map, in_ssrc) do
      {:ok, out} ->
        {out, state}

      :error ->
        out = fresh_ssrc(in_ssrc, map)
        {out, %{state | ssrc_map: Map.put(map, in_ssrc, out)}}
    end
  end

  defp map_ssrc(state, _in_ssrc) do
    out = :rand.uniform(0xFFFF_FFFF)
    {out, state}
  end

  defp fresh_ssrc(in_ssrc, map) do
    # Avoid colliding with the inbound SSRC or an already mapped outbound.
    used = MapSet.new([in_ssrc | Map.values(map)])

    Stream.repeatedly(fn -> :rand.uniform(0xFFFF_FFFF) end)
    |> Enum.find(fn ssrc -> not MapSet.member?(used, ssrc) end)
  end

  defp rtp_ssrc(%Rtp{ssrc: ssrc}) when is_integer(ssrc), do: ssrc
  defp rtp_ssrc(%{ssrc: ssrc}) when is_integer(ssrc), do: ssrc
  defp rtp_ssrc(_), do: nil

  defp prepare_echo_rtp(%Rtp{} = rtp, ssrc) do
    %{rtp | ssrc: ssrc, extension: nil, csrcs: []}
  end

  defp prepare_echo_rtp(%{} = rtp, ssrc) do
    rtp
    |> Map.put(:ssrc, ssrc)
    |> Map.put(:extension, nil)
    |> Map.put(:csrcs, [])
  end

  defp prepare_echo_rtp(rtp, _ssrc), do: rtp
end
