defmodule Xylon.Recording.SessionTest do
  use ExUnit.Case, async: false

  alias Xylon.Recording.{Ctx, Registry}

  defmodule SpyHandler do
    @behaviour Xylon.Recording.Handler

    @impl true
    def on_start(%Ctx{}, _opts) do
      {:ok, %{packets: 0}}
    end

    @impl true
    def on_stop(%Ctx{}, state), do: {:ok, state}

    @impl true
    def on_publisher_rtp(%Ctx{}, state, _meta, _rtp) do
      if pid = Application.get_env(:xylon, :recording_spy_pid) do
        send(pid, :publisher_rtp)
      end

      {:ok, Map.update(state, :packets, 1, &(&1 + 1))}
    end

    @impl true
    def on_mix_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok = Registry.ensure_table!()
    Application.put_env(:xylon, :recording, handler: Xylon.Recording.Null)

    on_exit(fn ->
      Application.delete_env(:xylon, :recording)
      Application.delete_env(:xylon, :recording_spy_pid)
    end)

    :ok
  end

  test "start get stop and conflict; sequence and preceded_by on restart" do
    sid = "rec-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)

    assert {:ok, first} = Xylon.Session.start_recording(session)
    assert is_binary(first.recording_id)
    assert first.sequence == 1
    assert first.preceded_by == nil
    assert first.mode == :tracks

    assert {:ok, ^first} = Xylon.Session.get_recording(session)
    assert {:error, :conflict} = Xylon.Session.start_recording(session)

    assert {mod, %Ctx{recording_id: rid}, _state} = Registry.get(session)
    assert mod == Xylon.Recording.Null
    assert rid == first.recording_id

    assert {:ok, stopped} = Xylon.Session.stop_recording(session)
    assert stopped.recording_id == first.recording_id
    assert stopped.status == "finalizing"
    assert Registry.get(session) == nil
    assert {:error, :not_found} = Xylon.Session.get_recording(session)

    assert {:ok, second} = Xylon.Session.start_recording(session)
    assert second.sequence == 2
    assert second.preceded_by == first.recording_id
    assert second.recording_id != first.recording_id

    assert {:ok, _} = Xylon.Session.stop_recording(session)
  end

  test "Registry maybe_publisher_rtp updates spy state without crashing" do
    Application.put_env(:xylon, :recording_spy_pid, self())
    Application.put_env(:xylon, :recording, handler: SpyHandler)
    sid = "spy-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)
    assert {:ok, _} = Xylon.Session.start_recording(session)

    :ok =
      Registry.maybe_publisher_rtp(
        session,
        %{publisher_id: "a", ssrc: 1, kind: :audio},
        :fake_rtp
      )

    assert_receive :publisher_rtp
    assert {_mod, _ctx, %{packets: 1}} = Registry.get(session)

    assert {:ok, _} = Xylon.Session.stop_recording(session)
  end

  test "omitted mode is tracks on Echo; tracks_and_mix when backend audio is mcu" do
    sid = "auto-sfu-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)
    assert {:ok, started} = Xylon.Session.start_recording(session)
    assert started.mode == :tracks
    assert {:ok, _} = Xylon.Session.stop_recording(session)

    # Inject MCU-shaped backend_state as Conference would store.
    :sys.replace_state(session, fn state ->
      %{state | backend_state: Map.put(state.backend_state || %{}, :audio, :mcu)}
    end)

    assert {:ok, mcu_started} = Xylon.Session.start_recording(session)
    assert mcu_started.mode == :tracks_and_mix
    assert {:ok, _} = Xylon.Session.stop_recording(session)

    assert {:ok, forced} = Xylon.Session.start_recording(session, mode: :tracks)
    assert forced.mode == :tracks
    assert {:ok, _} = Xylon.Session.stop_recording(session)
  end

  test "spoke SFU of hub mix (audio sfu + cascade spoke) stays tracks when mode omitted" do
    sid = "auto-spoke-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)

    :sys.replace_state(session, fn state ->
      %{
        state
        | backend_state:
            (state.backend_state || %{})
            |> Map.put(:audio, :sfu)
            |> Map.put(:mcu_cascade, :spoke)
      }
    end)

    assert {:ok, started} = Xylon.Session.start_recording(session)
    assert started.mode == :tracks
    assert {:ok, _} = Xylon.Session.stop_recording(session)
  end
end
