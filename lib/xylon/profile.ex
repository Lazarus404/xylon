defmodule Xylon.Profile do
  @moduledoc """
  Lab RTP hop sampler: attaches to forward and egress telemetry.

  ## What problem this solves

  Browser lag can be Forwarder mailbox buildup, slow SFU rewrite, **egress
  hold** (RTP re-clock waits after enqueue), or Chrome jitter-buffer expansion.
  This process records `[:xylon, :rtp, :forward]` durations and
  `[:xylon, :rtp, :egress]` `hold_us`, then logs p50/p99 every few seconds.
  `forward_us` alone is blind to SendWorker waits.

  Enable with `XYLON_RTP_PROFILE=1` (started from `Xylon.Application`).

  ## Internal

  Lab / operator harness. Not part of the public Session API.

  ## RFCs

  None -- operational telemetry only.
  """
  use GenServer

  require Logger

  @handler_forward "xylon-rtp-profile-forward"
  @handler_egress "xylon-rtp-profile-egress"
  @default_interval_ms 5_000
  @max_samples 4_000

  @doc "True when `XYLON_RTP_PROFILE` is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("XYLON_RTP_PROFILE") in ["1", "true", "yes"]
  end

  @doc "Child spec when profiling is enabled; otherwise `[]`."
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    if enabled?(), do: [{__MODULE__, []}], else: []
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    :ok =
      :telemetry.attach(
        @handler_forward,
        [:xylon, :rtp, :forward],
        &__MODULE__.handle_event/4,
        self()
      )

    :ok =
      :telemetry.attach(
        @handler_egress,
        [:xylon, :rtp, :egress],
        &__MODULE__.handle_event/4,
        self()
      )

    timer = Process.send_after(self(), :flush, interval)

    Logger.info(
      "xylon rtp profile on interval_ms=#{interval} (detach on terminate)"
    )

    {:ok,
     %{
       samples: [],
       mailboxes: [],
       forwarded: [],
       holds: [],
       by_kind: %{},
       interval: interval,
       timer: timer,
       count: 0,
       egress_count: 0
     }}
  end

  @impl true
  def terminate(_reason, _state) do
    _ = :telemetry.detach(@handler_forward)
    _ = :telemetry.detach(@handler_egress)
    :ok
  end

  @doc false
  def handle_event([:xylon, :rtp, :forward], measurements, meta, pid)
      when is_pid(pid) do
    send(pid, {:forward_sample, measurements, meta})
    :ok
  end

  def handle_event([:xylon, :rtp, :egress], measurements, meta, pid)
      when is_pid(pid) do
    send(pid, {:egress_sample, measurements, meta})
    :ok
  end

  @impl true
  def handle_info({:forward_sample, measurements, meta}, state) do
    dur = Map.get(measurements, :duration_us, 0)
    mb = Map.get(measurements, :mailbox, 0)
    fwd = Map.get(measurements, :forwarded, 0)
    kind = Map.get(meta, :kind, :unknown)

    samples = trim([dur | state.samples])
    mailboxes = trim([mb | state.mailboxes])
    forwarded = trim([fwd | state.forwarded])
    by_kind = Map.update(state.by_kind, kind, [dur], fn list -> trim([dur | list]) end)

    {:noreply,
     %{
       state
       | samples: samples,
         mailboxes: mailboxes,
         forwarded: forwarded,
         by_kind: by_kind,
         count: state.count + 1
     }}
  end

  def handle_info({:egress_sample, measurements, _meta}, state) do
    hold = Map.get(measurements, :hold_us, 0)
    holds = trim([hold | state.holds])

    {:noreply, %{state | holds: holds, egress_count: state.egress_count + 1}}
  end

  def handle_info(:flush, state) do
    log_summary(state)

    timer = Process.send_after(self(), :flush, state.interval)

    {:noreply,
     %{
       state
       | samples: [],
         mailboxes: [],
         forwarded: [],
         holds: [],
         by_kind: %{},
         count: 0,
         egress_count: 0,
         timer: timer
     }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp log_summary(%{count: 0, egress_count: 0}) do
    Logger.info("xylon rtp profile: no forward samples in window")
  end

  defp log_summary(state) do
    durs = Enum.sort(state.samples)
    mbs = Enum.sort(state.mailboxes)
    holds = Enum.sort(state.holds)
    fwds = state.forwarded
    fwd_mean = if fwds == [], do: 0, else: div(Enum.sum(fwds), length(fwds))

    kind_bits =
      state.by_kind
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {kind, list} ->
        sorted = Enum.sort(list)

        "#{kind} n=#{length(list)} p50=#{percentile(sorted, 50)} p99=#{percentile(sorted, 99)}"
      end)
      |> Enum.join(" ")

    kind_suffix = if kind_bits == "", do: "", else: " " <> kind_bits

    hold_bit =
      if state.egress_count == 0 do
        ""
      else
        " egress_hold_us p50=#{percentile(holds, 50)} p99=#{percentile(holds, 99)} max=#{List.last(holds) || 0}"
      end

    forward_bit =
      if state.count == 0 do
        "n=0"
      else
        "n=#{state.count} forward_us p50=#{percentile(durs, 50)} p99=#{percentile(durs, 99)} max=#{List.last(durs)} " <>
          "mailbox p50=#{percentile(mbs, 50)} max=#{List.last(mbs) || 0} " <>
          "forwarded_mean=#{fwd_mean}" <> kind_suffix
      end

    Logger.info("xylon rtp profile " <> forward_bit <> hold_bit)
  end

  defp percentile([], _), do: 0

  defp percentile(sorted, pct) do
    n = length(sorted)
    idx = min(n - 1, max(0, round(pct / 100 * (n - 1))))
    Enum.at(sorted, idx)
  end

  defp trim(list) when length(list) > @max_samples, do: Enum.take(list, @max_samples)
  defp trim(list), do: list
end
