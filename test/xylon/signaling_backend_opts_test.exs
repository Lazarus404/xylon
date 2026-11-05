defmodule Xylon.SignalingBackendOptsTest do
  use ExUnit.Case, async: true

  alias Xylon.Signaling

  test "parses subscribe_mode and max_publishers" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "subscribe_mode" => "manual",
               "max_publishers" => 3
             })

    assert Keyword.get(opts, :subscribe_mode) == :manual
    assert Keyword.get(opts, :max_publishers) == 3
  end

  test "parses mesh subscribe_mode" do
    assert {:ok, opts} = Signaling.backend_opts_from_map(%{"subscribe_mode" => "mesh"})
    assert Keyword.get(opts, :subscribe_mode) == :mesh
  end

  test "rejects invalid subscribe_mode" do
    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"subscribe_mode" => "policy"})
  end

  test "rejects zero max_publishers" do
    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"max_publishers" => 0})
  end

  test "parses audio and video strategies with mesh MCU recipe" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "audio" => "mcu",
               "video" => "sfu",
               "subscribe_mode" => "mesh"
             })

    assert Keyword.get(opts, :audio) == :mcu
    assert Keyword.get(opts, :video) == :sfu
    assert Keyword.get(opts, :subscribe_mode) == :mesh

    assert {:ok, sfu} =
             Signaling.backend_opts_from_map(%{"audio" => "sfu", "video" => "sfu"})

    assert Keyword.get(sfu, :audio) == :sfu
    assert Keyword.get(sfu, :video) == :sfu
  end

  test "rejects invalid audio and video strategies" do
    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"audio" => "mesh"})

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"video" => "mcu"})
  end

  test "parses mcu_cascade and mcu_mix_mid" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "mcu_cascade" => "hub",
               "mcu_mix_mid" => "0"
             })

    assert Keyword.get(opts, :mcu_cascade) == :hub
    assert Keyword.get(opts, :mcu_mix_mid) == "0"
  end

  test "parses mcu_cascade_trunk_profile and mcu_spoke_mix_minus" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "mcu_cascade_trunk_profile" => "pcm",
               "mcu_spoke_mix_minus" => true
             })

    assert Keyword.get(opts, :mcu_cascade_trunk_profile) == :pcm
    assert Keyword.get(opts, :mcu_spoke_mix_minus) == true

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"mcu_cascade_trunk_profile" => "g722"})
  end

  test "rejects invalid mcu_cascade" do
    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"mcu_cascade" => "edge"})
  end

  test "parses mcu_max_participants and mcu_max_contributors" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "mcu_max_participants" => 8,
               "mcu_max_contributors" => 4
             })

    assert Keyword.get(opts, :mcu_max_participants) == 8
    assert Keyword.get(opts, :mcu_max_contributors) == 4
  end

  test "rejects zero mcu_max_participants" do
    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"mcu_max_participants" => 0})
  end

  test "keeps datachannel keys and rejects unknown" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "mode" => "fanout_all",
               "subscribe_mode" => "mesh"
             })

    assert Keyword.get(opts, :mode) == :fanout_all
    assert Keyword.get(opts, :subscribe_mode) == :mesh

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"nope" => true})
  end

  test "parses audiolevel_events and Janus audio-level knobs" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "audiolevel_events" => true,
               "audio_active_packets" => 50,
               "audio_level_average" => 30
             })

    assert Keyword.get(opts, :audiolevel_events) == true
    assert Keyword.get(opts, :audio_active_packets) == 50
    assert Keyword.get(opts, :audio_level_average) == 30
  end

  test "rejects non-positive audio_active_packets and audio_level_average" do
    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"audio_active_packets" => 0})

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"audio_level_average" => 0})
  end

  test "rejects non-boolean audiolevel_events" do
    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"audiolevel_events" => "yes"})
  end

  test "parses bitrate_cap" do
    assert {:ok, opts} = Signaling.backend_opts_from_map(%{"bitrate_cap" => 1_000_000})
    assert Keyword.get(opts, :bitrate_cap) == 1_000_000

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"bitrate_cap" => 0})
  end

  test "parses twcc_period_ms" do
    assert {:ok, opts} = Signaling.backend_opts_from_map(%{"twcc_period_ms" => 50})
    assert Keyword.get(opts, :twcc_period_ms) == 50

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"twcc_period_ms" => 0})
  end

  test "parses fir_interval_ms including zero off" do
    assert {:ok, opts} = Signaling.backend_opts_from_map(%{"fir_interval_ms" => 5000})
    assert Keyword.get(opts, :fir_interval_ms) == 5000

    assert {:ok, opts0} = Signaling.backend_opts_from_map(%{"fir_interval_ms" => 0})
    assert Keyword.get(opts0, :fir_interval_ms) == 0

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"fir_interval_ms" => -1})
  end

  test "parses datachannel default_dest and rpc_router" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "mode" => "mfu",
               "default_dest" => "except_sender",
               "rpc_router" => true,
               "state_coalesce" => true,
               "labels" => ["chat", "rpc", "state"]
             })

    assert Keyword.get(opts, :mode) == :mfu
    assert Keyword.get(opts, :default_dest) == :except_sender
    assert Keyword.get(opts, :rpc_router) == true
    assert Keyword.get(opts, :state_coalesce) == true
    assert Keyword.get(opts, :labels) == ["chat", "rpc", "state"]

    assert {:ok, opts_off} = Signaling.backend_opts_from_map(%{"rpc_router" => false})
    assert Keyword.get(opts_off, :rpc_router) == false

    assert {:ok, coalesce_off} =
             Signaling.backend_opts_from_map(%{"state_coalesce" => false})

    assert Keyword.get(coalesce_off, :state_coalesce) == false

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"default_dest" => "subset"})
  end

  test "parses rate_limit and on_no_channel" do
    assert {:ok, opts} =
             Signaling.backend_opts_from_map(%{
               "rate_limit" => %{"max_per_sec" => 50, "burst" => 100},
               "on_no_channel" => "buffer"
             })

    assert Keyword.get(opts, :rate_limit) == {:token_bucket, 50, 100}
    assert Keyword.get(opts, :on_no_channel) == :buffer

    assert {:ok, skip} = Signaling.backend_opts_from_map(%{"on_no_channel" => "skip"})
    assert Keyword.get(skip, :on_no_channel) == :skip

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"rate_limit" => %{"max_per_sec" => 0, "burst" => 1}})

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"on_no_channel" => "drop"})
  end

  test "parses codec json, msgpack, and cbor" do
    assert {:ok, json_opts} = Signaling.backend_opts_from_map(%{"codec" => "json"})
    assert Keyword.get(json_opts, :codec) == Xylon.Datachannel.Codec.JSON

    assert {:ok, mp_opts} = Signaling.backend_opts_from_map(%{"codec" => "msgpack"})
    assert Keyword.get(mp_opts, :codec) == Xylon.Datachannel.Codec.Msgpack

    assert {:ok, cbor_opts} = Signaling.backend_opts_from_map(%{"codec" => "cbor"})
    assert Keyword.get(cbor_opts, :codec) == Xylon.Datachannel.Codec.Cbor

    assert {:error, :bad_backend_opts} =
             Signaling.backend_opts_from_map(%{"codec" => "protobuf"})
  end
end

