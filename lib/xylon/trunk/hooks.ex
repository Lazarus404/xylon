defmodule Xylon.Trunk.Hooks do
  @moduledoc """
  Optional catalogue hooks when a trunk announce lands on a Session.

  ## What problem this solves

  Conference and datachannel packages need Plan/label install for remote
  publishers without Xylon depending on them at compile time. This module
  calls into those packages only when loaded. On MCU hubs, remote talker
  audio is not mesh-subscribed to locals (mix bus owns audio); remote video
  and `__mcu_mix__` audio still mesh to local peers.

  ## RFCs

  None.
  """

  alias Xylon.Participant

  @doc """
  Applies announce side-effects for `participant` on `session`.

  Returns `{:error, :mcu_cascade_profile_mismatch}` when a mix announce
  carries a trunk_profile that disagrees with the local room opt.
  """
  @spec apply_announce(pid(), Participant.t(), map()) :: :ok | {:error, term()}
  def apply_announce(session, %Participant{} = participant, announcement)
      when is_pid(session) and is_map(announcement) do
    with :ok <- maybe_conference(session, participant, announcement) do
      _ = maybe_datachannel(session, participant, announcement)
      :ok
    end
  end

  defp maybe_conference(session, participant, announcement) do
    if Code.ensure_loaded?(Xylon.Conference.Plan) do
      plan_ref = Xylon.Session.plan_ref(session)

      if plan_ref do
        participant = maybe_tag_mcu_mix(participant)

        with :ok <- check_mix_trunk_profile(session, participant) do
          _ = apply(Xylon.Conference.Plan, :put_participant, [plan_ref, participant])

          Enum.each(Map.get(participant.meta, :tracks, []), fn track ->
            mid = Map.get(track, :mid, "0")
            kind = Map.get(track, :kind, :audio)
            ssrc = Map.get(track, :ssrc, 0)

            _ =
              apply(Xylon.Conference, :publish, [
                plan_ref,
                participant.id,
                %{mid: mid, kind: kind, ssrc: ssrc}
              ])

            _ = maybe_hub_remote_contrib(session, participant, kind)
          end)

          maybe_mesh_subscribe_locals(session, plan_ref, participant, announcement)
          :ok
        end
      else
        :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp check_mix_trunk_profile(session, participant) do
    mix? =
      Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) and
        apply(Xylon.Conference.Mcu.Cascade, :mix_publisher?, [participant.id])

    if mix? do
      state = :sys.get_state(session)

      remote =
        Map.get(participant.meta || %{}, :trunk_profile) ||
          Enum.find_value(Map.get(participant.meta || %{}, :tracks, []), fn t ->
            Map.get(t, :trunk_profile)
          end)

      if remote do
        apply(Xylon.Conference.Mcu.Cascade, :agree_trunk_profile, [
          Map.get(state.backend_state, :mcu_cascade_trunk_profile),
          remote
        ])
      else
        :ok
      end
    else
      :ok
    end
  end

  defp maybe_tag_mcu_mix(%Participant{id: id, meta: meta} = p) do
    if id == "__mcu_mix__" do
      meta = meta || %{}
      meta = Map.put(meta, :mcu_mix, true)

      spoke_mm? =
        Enum.any?(Map.get(meta, :tracks, []), fn t ->
          Map.get(t, :spoke_mix_minus) == true
        end)

      meta = if spoke_mm?, do: Map.put(meta, :spoke_mix_minus, true), else: meta

      profile =
        Enum.find_value(Map.get(meta, :tracks, []), fn t ->
          Map.get(t, :trunk_profile)
        end)

      meta =
        if profile do
          Map.put(meta, :trunk_profile, profile)
        else
          meta
        end

      %{p | meta: meta}
    else
      p
    end
  end

  defp maybe_hub_remote_contrib(session, participant, :audio) do
    state = :sys.get_state(session)

    mix? =
      Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) and
        apply(Xylon.Conference.Mcu.Cascade, :mix_publisher?, [participant.id])

    cascade = Map.get(state.backend_state, :mcu_cascade)
    audio = Map.get(state.backend_state, :audio)

    cond do
      mix? and cascade == :spoke and
          (audio == :mcu or pcm_sfu_edge?(state.backend_state)) and
          Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) ->
        _ =
          apply(Xylon.Conference.Mcu.Cascade, :ensure_remote_contributor, [
            state.backend_state.plan_ref,
            participant.id,
            state.backend_state
          ])

        :ok

      not mix? and cascade == :hub and
          Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) ->
        _ =
          apply(Xylon.Conference.Mcu.Cascade, :ensure_remote_contributor, [
            state.backend_state.plan_ref,
            participant.id,
            state.backend_state
          ])

        :ok

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_hub_remote_contrib(_, _, _), do: :ok

  defp pcm_sfu_edge?(backend) do
    is_map(backend) and Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) and
      apply(Xylon.Conference.Mcu.Cascade, :pcm_sfu_edge?, [backend])
  end

  defp maybe_mesh_subscribe_locals(session, plan_ref, remote, _announcement) do
    state = :sys.get_state(session)
    fwd = state.forwarder
    backend = state.backend_state || %{}
    audio = Map.get(backend, :audio)
    cascade = Map.get(backend, :mcu_cascade)
    pcm_edge? = pcm_sfu_edge?(backend)

    Enum.each(state.participants, fn {id, p} ->
      if id != remote.id and p.role != :trunk and not Map.get(p.meta || %{}, :remote, false) do
        Enum.each(Map.get(remote.meta, :tracks, []), fn track ->
          mid = Map.get(track, :mid, "0")
          kind = Map.get(track, :kind, :audio)

          # MCU hubs fan out remote video via SFU; remote talker audio enters the
          # mix bus (Cascade) and must not also SFU-fanout to local listeners.
          # Spoke MCU and PCM SFU edge-transcode decode the mix instead of SFU.
          mix? =
            Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) and
              apply(Xylon.Conference.Mcu.Cascade, :mix_publisher?, [remote.id])

          allow? =
            cond do
              mix? and kind == :audio and cascade == :spoke and
                  (audio == :mcu or pcm_edge?) ->
                false

              mix? ->
                true

              audio != :mcu or kind != :audio ->
                true

              true ->
                false
            end

          if allow? do
            _ =
              apply(Xylon.Conference, :subscribe, [
                plan_ref,
                id,
                remote.id,
                mid,
                [forwarder: fwd]
              ])
          end

          if mix? and kind == :audio and pcm_edge? and
               Code.ensure_loaded?(Xylon.Conference.Mcu.Egress) and
               Code.ensure_loaded?(Xylon.Conference.Mcu.Cascade) do
            opus = apply(Xylon.Conference.Mcu.Cascade, :opus_desc, [])
            _ = apply(Xylon.Conference.Mcu.Egress, :ensure, [plan_ref, id, opus])
          end
        end)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_datachannel(session, participant, announcement) do
    if Code.ensure_loaded?(Xylon.Datachannel.Backend) do
      labels = Map.get(participant.meta, :labels, []) ++ announce_labels(announcement)
      pipe = participant.peer_ref

      if is_pid(pipe) do
        Enum.each(Enum.uniq(labels), fn
          label when is_binary(label) ->
            case XGW.Trunk.Pipe.ensure_label(pipe, label) do
              {:ok, ref} ->
                send(session, {:xgw, :datachannel, pipe, %{ref: ref, label: label, id: 0}})

              _ ->
                :ok
            end

          _ ->
            :ok
        end)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp announce_labels(%{participants: parts}) when is_list(parts) do
    Enum.flat_map(parts, fn p -> Map.get(p, :labels, []) end)
  end

  defp announce_labels(_), do: []
end
