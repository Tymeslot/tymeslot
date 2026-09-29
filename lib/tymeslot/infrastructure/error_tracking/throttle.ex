defmodule Tymeslot.Infrastructure.ErrorTracking.Throttle do
  @moduledoc """
  Caps how many occurrences of one error ErrorTracker stores per minute.

  Every report is a synchronous read and a two-insert transaction on the
  primary database, made in the process that failed. A chronic 5xx, or a
  provider outage failing every sync job, would otherwise write one
  occurrence per failure for as long as it lasts: a write storm during the
  incident, and a month of rows after it.

  `allow?/1` is asked by `Tymeslot.Infrastructure.ErrorTracking.Ignorer`
  before anything is written. It counts reports per error fingerprint, the
  hash ErrorTracker has already computed from the error's kind and source
  line, in fixed windows: the first `:max_per_window` of a window are
  stored, the rest are dropped and counted. The first occurrence of an error
  always passes, so neither a new error nor a regression is ever hidden from
  the alerting.

  The counters are one ETS table per node, owned by this process, which
  every window deletes the windows gone by and logs, per fingerprint, how
  many occurrences it dropped. So the cap is per node: a cluster stores at
  most the cap times its node count, which bounds the storm all the same.

  ## Configuration

      config :tymeslot, :error_tracking_throttle,
        max_per_window: 10,
        window_seconds: 60

  `max_per_window: nil` switches the throttle off (the test suite does, so
  counts cannot leak from one test into another). Read on every report.

  A missing table (a report during boot, before this process starts) or any
  other failure lets the report through: a broken throttle must never cost
  the record of an error.
  """

  use GenServer

  require Logger

  @table __MODULE__

  @default_max_per_window 10
  @default_window_seconds 60

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one report of the error with `fingerprint` and returns whether it
  may be stored.
  """
  @spec allow?(binary() | nil) :: boolean()
  def allow?(fingerprint) when is_binary(fingerprint) do
    case settings() do
      {nil, _window_ms} ->
        true

      {max, window_ms} ->
        key = {fingerprint, window(window_ms)}
        :ets.update_counter(@table, key, {2, 1}, {key, 0}) <= max
    end
  rescue
    # No table yet, or a malformed setting: store the report.
    # credo:disable-for-next-line CredoChecks.NoSwallowedException
    _exception -> true
  end

  def allow?(_no_fingerprint), do: true

  @doc """
  Deletes the counters of every window before the current one, logging the
  occurrences each fingerprint had dropped in them. Run by this process once
  a window; public so a test can run it at once.
  """
  @spec sweep() :: :ok
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  @impl GenServer
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state) do
    do_sweep()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    do_sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp do_sweep do
    {max, window_ms} = settings()
    current = window(window_ms)
    past = [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}]

    if is_integer(max), do: log_dropped(max, current)

    _deleted = :ets.select_delete(@table, past)
    :ok
  end

  # A fold rather than a match spec: the table holds a few rows a minute.
  defp log_dropped(max, current) do
    :ets.foldl(
      fn
        {{fingerprint, window}, count}, :ok when window < current and count > max ->
          Logger.warning("ErrorTracker occurrences throttled",
            fingerprint: fingerprint |> Base.encode16(case: :lower) |> binary_part(0, 16),
            stored: max,
            dropped: count - max
          )

        _row, :ok ->
          :ok
      end,
      :ok,
      @table
    )
  end

  defp schedule_sweep do
    {_max, window_ms} = settings()
    Process.send_after(self(), :sweep, window_ms)
  end

  # Wall-clock time, which is positive, so window numbers only ever grow;
  # monotonic time may be negative, where `div/2` rounds towards zero. A clock
  # step at worst starts one window early or late.
  defp window(window_ms), do: div(System.os_time(:millisecond), window_ms)

  defp settings do
    config = Application.get_env(:tymeslot, :error_tracking_throttle, [])

    {Keyword.get(config, :max_per_window, @default_max_per_window),
     Keyword.get(config, :window_seconds, @default_window_seconds) * 1_000}
  end
end
