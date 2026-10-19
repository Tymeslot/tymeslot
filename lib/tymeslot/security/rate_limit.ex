defmodule Tymeslot.Security.RateLimit do
  @moduledoc """
  Sliding-log rate limiter over one public ETS table.

  Every hit is a row `{bucket_key, seq, inserted_at_us, expires_at_us}`, and a
  hit is allowed while its bucket holds no more than `limit` live rows, its own
  included. Counting individual hits rather than per-window counters means no
  window edge lets twice the limit through.

  `seq` is a node-wide monotonic integer, so every hit is a row of its own: two
  hits on one bucket in the same microsecond both count, and a burst of
  simultaneous requests from one source cannot exceed the limit.

  Denied hits are recorded as well, deliberately. A source that keeps sending
  past its limit stays refused for as long as it keeps sending, rather than
  being let through `limit` times in every window. Every check is linear in
  its bucket's rows, so a bucket keeps only its newest `limit + 1` hits: enough
  to stay over the limit while a flood lasts, and a flood cannot make one
  bucket's checks grow without bound. Once the hits stop, the refusal ends
  as soon as enough kept hits have expired for one more to fit, which for a
  flood is about one window after it stopped.

  A refusal says how long until a retry would be allowed: until enough kept
  hits expire that the bucket, with the retry's own hit added, holds no more
  than `limit`.

  Windows run on monotonic time, so a step in the wall clock neither stretches
  nor cuts short a live window; the table lives in memory and dies with the
  node, so nothing reads its timestamps as wall time.

  Checks run in the caller's process against the table. This process only
  owns the table and sweeps expired rows every `:clean_period`. If it restarts,
  its table goes with it; a check or clear in that gap is allowed and logged
  once, since every bucket starts empty afterwards anyway. A check that fails
  because the table was replaced under it is retried once against the new one.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @gap_logged {__MODULE__, :gap_logged}
  @default_clean_period :timer.minutes(1)

  @type key :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Charges one hit to `key` and answers whether it is within `limit` hits per
  `window_ms`: `{:allow, count}` with the hits now in the window, or
  `{:deny, wait_ms}` with the time until a retry would be allowed.
  """
  @spec hit(key(), pos_integer(), non_neg_integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(key, window_ms, limit), do: hit(key, window_ms, limit, now())

  @doc false
  @spec hit(key(), pos_integer(), non_neg_integer(), integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(key, window_ms, limit, now) when is_binary(key) do
    guarded({:allow, 0}, fn ->
      :ets.select_delete(@table, expired(key, now))
      :ets.insert(@table, {key, seq(), now, now + window_ms * 1000})

      case :ets.select_count(@table, live(key, now, true)) do
        count when count <= limit -> {:allow, count}
        _over -> {:deny, refuse(key, now, limit)}
      end
    end)
  end

  @doc "How many hits `key` holds inside its window, without charging it."
  @spec get(key(), pos_integer()) :: non_neg_integer()
  def get(key, _window_ms) when is_binary(key) do
    guarded(0, fn -> :ets.select_count(@table, live(key, now(), true)) end)
  end

  @doc """
  How long until one more hit on `key` would be allowed under `limit`,
  without charging it: 0 when it would be allowed now.
  """
  @spec retry_after(key(), non_neg_integer()) :: non_neg_integer()
  def retry_after(key, limit) when is_binary(key) do
    guarded(0, fn ->
      now = now()
      @table |> :ets.select(live(key, now, :"$1")) |> wait_ms(now, limit)
    end)
  end

  @doc "Drops every hit `key` holds."
  @spec clear(key()) :: :ok
  def clear(key) when is_binary(key) do
    guarded(:ok, fn ->
      :ets.delete(@table, key)
      :ok
    end)
  end

  @doc "Drops every hit in every bucket."
  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc false
  # Every hit `key` holds, live or not yet swept, as `{inserted_at_us,
  # expires_at_us}`, oldest first. For tests that check what was charged.
  @spec entries(key()) :: [{integer(), integer()}]
  def entries(key) when is_binary(key) do
    @table
    |> :ets.lookup(key)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(fn {_key, _seq, inserted_at, expires_at} -> {inserted_at, expires_at} end)
  end

  @doc false
  # Every bucket key holding at least one row. For tests.
  @spec keys() :: [key()]
  def keys do
    @table
    |> :ets.select([{{:"$1", :_, :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  @doc false
  # Removes every expired row in every bucket; returns how many.
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now \\ now()) do
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  @doc false
  # The limiter's clock, for tests that pass their own `now`.
  @spec now() :: integer()
  def now, do: System.monotonic_time(:microsecond)

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [
      :named_table,
      :duplicate_bag,
      :public,
      read_concurrency: true,
      write_concurrency: true,
      decentralized_counters: true
    ])

    :persistent_term.erase(@gap_logged)
    clean_period = Keyword.get(opts, :clean_period, @default_clean_period)
    schedule_clean(clean_period)
    {:ok, clean_period}
  end

  @impl GenServer
  def handle_info(:clean, clean_period) do
    sweep()
    schedule_clean(clean_period)
    {:noreply, clean_period}
  end

  defp schedule_clean(clean_period), do: Process.send_after(self(), :clean, clean_period)

  # Keys are binaries, so they are safe as literals in a match-spec head; a
  # bound key lets ETS go straight to the bucket instead of scanning the table.
  defp expired(key, now), do: [{{key, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
  defp live(key, now, result), do: [{{key, :_, :_, :"$1"}, [{:>, :"$1", now}], [result]}]

  # Only a refused hit reads the bucket's rows: it trims them to the newest
  # `limit + 1` and works out the wait from what is kept.
  defp refuse(key, now, limit) do
    @table
    |> :ets.select(live(key, now, :"$_"))
    |> trim(limit + 1)
    |> Enum.map(&elem(&1, 3))
    |> wait_ms(now, limit)
  end

  # Drops the oldest rows past `cap`, returning the rows kept. A bucket held
  # `cap` rows before this hit, so one row is the usual excess; more only when
  # concurrent hits landed together. Concurrent callers trimming the same
  # bucket each drop the oldest by `seq`, so together they never leave fewer
  # than `cap` rows.
  defp trim(rows, cap) do
    case length(rows) - cap do
      excess when excess <= 0 ->
        rows

      1 ->
        oldest = Enum.min_by(rows, &elem(&1, 1))
        :ets.delete_object(@table, oldest)
        List.delete(rows, oldest)

      excess ->
        {dropped, kept} = rows |> Enum.sort_by(&elem(&1, 1)) |> Enum.split(excess)
        Enum.each(dropped, &:ets.delete_object(@table, &1))
        kept
    end
  end

  # A retry adds a hit of its own, so it is allowed once no more than
  # `limit - 1` hits are live: the earliest `length - limit + 1` expiries have
  # to have passed. A capped bucket holds at most `limit + 1`, so that is the
  # first or the second to expire. A hit counts until its expiry and not at
  # it, and the wait rounds up, so a retry exactly when told is allowed and
  # one a millisecond sooner is not. An empty bucket (cleared between the
  # count and the read) waits for nothing.
  defp wait_ms(expiries, now, limit) do
    case length(expiries) - limit do
      excess when excess < 0 or expiries == [] -> 0
      excess -> max(ceil((nth_earliest(expiries, excess) - now) / 1000), 0)
    end
  end

  defp nth_earliest(expiries, 0), do: Enum.min(expiries)

  defp nth_earliest(expiries, 1) do
    {first, second} =
      Enum.reduce(expiries, {nil, nil}, fn
        expiry, {nil, nil} -> {expiry, nil}
        expiry, {first, _second} when expiry < first -> {expiry, first}
        expiry, {first, second} when is_nil(second) or expiry < second -> {first, expiry}
        _expiry, acc -> acc
      end)

    second || first
  end

  defp nth_earliest(expiries, n), do: expiries |> Enum.sort() |> Enum.at(n)

  # A missing table is the restart gap, answered with `gap_answer`. An
  # ArgumentError with the table present means it was replaced while the
  # operation ran, so the operation runs once more against the new one; a
  # second failure with the table present is a bug and is raised.
  defp guarded(gap_answer, operation, attempts \\ 2) do
    operation.()
  rescue
    error in ArgumentError ->
      cond do
        :ets.whereis(@table) == :undefined -> table_gap(gap_answer)
        attempts > 1 -> guarded(gap_answer, operation, attempts - 1)
        true -> reraise error, __STACKTRACE__
      end
  end

  defp table_gap(answer) do
    unless :persistent_term.get(@gap_logged, false) do
      :persistent_term.put(@gap_logged, true)
      Logger.warning("Rate limit table missing; allowing checks until it restarts")
    end

    answer
  end

  defp seq, do: System.unique_integer([:monotonic, :positive])
end
