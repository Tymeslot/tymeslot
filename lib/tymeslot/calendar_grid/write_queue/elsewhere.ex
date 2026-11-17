defmodule Tymeslot.CalendarGrid.WriteQueue.Elsewhere do
  @moduledoc """
  The events and series a `Tymeslot.CalendarGrid.WriteQueue` waits for
  while another driver writes them, as a plain map from what is lent to
  how the queue waits for it. Every function here takes and answers that
  map alone; starting, dropping and showing the writes it keeps stays with
  `WriteQueue`, which owns the effects.

  ## Events another driver is writing

  A grid mounted while another driver of the same organiser (an older
  LiveView whose connection dropped, or another tab) still has writes for an
  event can make no write to it of its own: the two would race, and since
  every write sends the whole event, an older one landing last would undo a
  newer one. So the grid's queue waits for that event elsewhere
  (`WriteQueue.wait_elsewhere/2`): its writes to it are kept, not started,
  until every driver it waits for has finished with the event and said so
  (`WriteQueue.resume/2`), passing on the event as its writes left it. They
  then start, in order, from that event; after a write to the whole series,
  which leaves the occurrence they were made against behind, they are
  dropped and counted.

  A series the other driver holds, while it writes or moves the whole of
  it, is waited for the same way, as `{:series, series}`: every write to an
  event of the series is kept until the driver has finished with it, and
  dropped and counted if the series changed, as it is in a hold.

  Each event is lent with the series it belongs to, so that while another
  driver writes one occurrence, this queue counts the series as busy and
  saving, and the grid refuses a write to the whole of it, as it does while
  one of its own occurrence writes runs. A write to the whole series that
  still succeeds (one already running when the grid mounted) drops and
  counts the writes kept for the series' events, and the event the other
  driver later passes on is ignored as `:outdated`: it predates the series
  change, so the writes made since start from the event they were made on.
  A driver that passes on a series change does the same here: the writes
  kept for every event of that series are dropped and counted, including an
  event a third driver is still writing, whose own release could not know
  of the change.
  """

  @typedoc """
  What one driver lends another: an event, known by its integration and
  uid, or `{:series, series}`, every event of a series it holds.
  """
  @type lent :: {integer() | nil, String.t()} | {:series, term()}

  @typedoc """
  What one driver lends another, each with the series it belongs to, or
  `nil` for an event outside an addressable series.
  """
  @type lends :: %{lent() => term()}

  @typedoc """
  The event as another driver's writes left it: the event as last accepted,
  `:series_changed` after a write to its whole series, `:outdated` once a
  write to its whole series made here has made any event passed on from
  there stale, or `:unknown`.
  """
  @type left :: {:ok, map()} | :series_changed | :outdated | :unknown

  @typedoc "Another driver finished with an event or series: `{driver, lent, left}`."
  @type release :: {pid(), lent(), left()}

  @typedoc """
  How the queue waits for one lent event or series: the drivers it waits
  for, the writes kept meanwhile (newest first, each with the event it was
  made on), how the event was left, and its series.
  """
  @type waiting :: %{
          from: MapSet.t(pid()),
          held: [{map(), map()}],
          left: left(),
          series: term()
        }

  @type t :: %{lent() => waiting()}

  @doc """
  Waits for what each driver in `lends`, given as `{driver, lends}`, is
  still writing, leaving out everything in `own`, what the queue already
  writes or waits for. Every lend is checked against `own` alone, so an
  event that two drivers lend is waited for from both.
  """
  @spec wait(t(), [{pid(), lends()}], MapSet.t(lent())) :: t()
  def wait(elsewhere, lends, own) do
    for {driver, lent} <- lends,
        {key, series} <- lent,
        not MapSet.member?(own, key),
        reduce: elsewhere do
      elsewhere ->
        series = lent_series(key, series)

        Map.update(
          elsewhere,
          key,
          %{from: MapSet.new([driver]), held: [], left: :unknown, series: series},
          &%{&1 | from: MapSet.put(&1.from, driver), series: &1.series || series}
        )
    end
  end

  defp lent_series({:series, series}, _series), do: series
  defp lent_series(_key, series), do: series

  @doc """
  Records that `driver` has finished with `lent`, leaving it as `left`,
  answering the updated wait with the map, or `:not_waiting` when the queue
  does not wait for `lent`.
  """
  @spec release(t(), release()) :: {:ok, waiting(), t()} | :not_waiting
  def release(elsewhere, {driver, lent, left}) do
    case elsewhere do
      %{^lent => %{from: from} = waiting} ->
        waiting = %{waiting | from: MapSet.delete(from, driver), left: latest(waiting.left, left)}
        {:ok, waiting, Map.put(elsewhere, lent, waiting)}

      _not_waiting ->
        :not_waiting
    end
  end

  @doc """
  Once no driver the queue waits for on `lent` is left, ends the wait,
  answering the writes kept for it, oldest first, and how it was left;
  `:waiting` while a driver is still writing it.
  """
  @spec finish(t(), lent()) :: {:done, [{map(), map()}], left(), t()} | :waiting
  def finish(elsewhere, lent) do
    waiting = Map.fetch!(elsewhere, lent)

    if MapSet.size(waiting.from) > 0,
      do: :waiting,
      else: {:done, Enum.reverse(waiting.held), waiting.left, Map.delete(elsewhere, lent)}
  end

  @doc "Keeps `write`, made on `event`, until the wait for `lent` ends."
  @spec keep(t(), lent(), map(), map()) :: t()
  def keep(elsewhere, lent, event, write),
    do: Map.update!(elsewhere, lent, &%{&1 | held: [{event, write} | &1.held]})

  @doc """
  How an event was left, from how it was left before and `left` since: a
  release that knows nothing (`:unknown`) does not undo one that did, and an
  event passed on from before a series change does not undo the change.
  """
  @spec latest(left(), left()) :: left()
  def latest(left, :unknown), do: left
  def latest(:series_changed, _stale), do: :series_changed
  def latest(:outdated, {:ok, _stale}), do: :outdated
  def latest(_older, left), do: left

  @doc """
  Drops the writes kept for what is lent of `series`, once the series
  changed, and marks what the lending driver passes on as stale; answers
  how many were dropped. The waits stay: the other driver's writes are
  still running.
  """
  @spec outdate(t(), term()) :: {t(), non_neg_integer()}
  def outdate(elsewhere, nil), do: {elsewhere, 0}

  def outdate(elsewhere, series) do
    {elsewhere, count} =
      Enum.map_reduce(elsewhere, 0, fn
        {lent, %{series: ^series} = waiting}, count ->
          {{lent, %{waiting | held: [], left: latest(waiting.left, :outdated)}},
           count + length(waiting.held)}

        entry, count ->
          {entry, count}
      end)

    {Map.new(elsewhere), count}
  end

  @doc "What the queue waits for, each with the series it belongs to."
  @spec lends(t()) :: lends()
  def lends(elsewhere), do: Map.new(elsewhere, fn {lent, waiting} -> {lent, waiting.series} end)

  @doc "What the queue waits for in `series`."
  @spec lent_in(t(), term()) :: [lent()]
  def lent_in(elsewhere, series), do: for({lent, %{series: ^series}} <- elsewhere, do: lent)

  @doc "The writes kept for each series another driver holds."
  @spec series_holds(t()) :: [{term(), [{map(), map()}]}]
  def series_holds(elsewhere),
    do: for({{:series, series}, waiting} <- elsewhere, do: {series, waiting.held})
end
