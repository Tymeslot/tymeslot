defmodule Tymeslot.CalendarGrid.WriteQueue do
  @moduledoc """
  The order in which the calendar grid writes its edits of existing events,
  as plain data, so that whichever process drives it (the grid's LiveView,
  or `Tymeslot.CalendarGrid.WriteGuardian` once the LiveView is gone) makes
  exactly the same writes in exactly the same order.

  Every function that changes the queue answers `{queue, effects}`. The
  effects are what the driver must do, in order:

    * `{:start, write, event}`: start `write` against `event` (see
      `Tymeslot.CalendarGrid.QueuedWrite.perform/3`), and hand its result
      back to `settle/3`;
    * `{:show, event}`: show `event` on the grid in place of its row;
    * `:reload`: reload the grid's events;
    * `{:notify, notify, updated_event, scope}`: ask the organiser whether to
      tell the event's attendees, once a write made with `notify` was
      accepted in `scope`;
    * `{:dropped, :series_write | :series_move, count}`: tell the organiser
      that `count` changes were not applied.

  Only `:start` reaches the provider; the others are for the screen, and a
  driver with no screen ignores them.

  ## One write in flight per event

  Each event, known by its integration and uid, has at most one write in
  flight. A write made while another is running waits in the event's
  chain, and starts once the running one has answered, whether it
  succeeded or failed. Writes to different events still run side by side.

  Each write carries only its own change, and is applied to the event as the
  provider last accepted it (the chain's `confirmed` event), not to the grid's
  copy at the moment it was made. The grid's copy already shows every earlier
  write's change, and every provider write sends the whole event, so a write
  built from it would quietly carry an earlier write's change even after that
  write had failed, and would send the event without what an earlier success
  added on the provider's side (a video room's join line in the description).
  So a waiting write cannot be finalised until the write before it answers.

  ## When a write fails

  Only the failed write's change is taken back. When writes are still waiting
  behind it, they still run, and the grid shows the confirmed event with the
  waiting writes' changes on top of it. When nothing is waiting, the grid goes
  back to the confirmed event. So once an event's queue drains, the grid
  shows what the provider holds.

  An edit that could not reach the provider but was saved to sync later
  (`:queued`) counts as accepted: the next write starts from it, as the
  queued replay will.

  ## After a write to a whole series

  A write of this and following events, or of all events, of a recurring
  series (`:recurrence_scope` `:following` or `:all`) can move every
  occurrence, and the grid's cached rows of the series are dropped until a
  sync brings them back (see `Tymeslot.CalendarGrid.SeriesEdit`). When one
  succeeds, the grid reloads its events.

  The writes still waiting behind it for the same event are dropped, not
  run. They were made against the occurrence as it was, whose row, and for
  a split its uid, may no longer exist, and the chain's `confirmed` event
  is no longer what the provider holds; running them could write a stale
  copy of the event over the series-wide change, or to an occurrence the
  series has left. The organiser is told how many changes were not applied.

  A series moved to another calendar is not one of these writes, but it
  ends the same way (`series_moved/2`): every write held while it was
  moving is dropped and counted, and the grid reloads.

  ## While a whole series is written or moved

  Queueing by event alone would let an edit of another occurrence of the
  series run alongside a write to the whole of it, or its move, and land
  on the series as it was.

  So while such a write or move is running, the series is held, known by
  its integration and address (`Tymeslot.CalendarGrid.Occurrence.series_address/1`)
  as read when it started. A write to any other event of the series waits
  in the hold, not started, until the series write or move answers.
  Writes to the event the series write was made from queue behind it as
  before. When the series was changed, the held writes are dropped with
  the ones queued behind it, and counted in the same warning; when it was
  not, they start in the order they were made.

  ## Events another driver is writing

  A grid mounted while another driver of the same organiser (an older
  LiveView whose connection dropped, or another tab) still has writes for an
  event can make no write to it of its own: the two would race, and since
  every write sends the whole event, an older one landing last would undo a
  newer one. So the grid's queue waits for that event elsewhere
  (`wait_elsewhere/3`): its writes to it are kept, not started, until every
  driver it waits for has finished with the event and said so (`resume/2`),
  passing on the event as its writes left it. They then start, in order,
  from that event; after a write to the whole series, which leaves the
  occurrence they were made against behind, they are dropped and counted.

  ## References

  Every write carries a reference, `{key, seq}`, where `seq` rises with every
  write taken by any queue on the node, so no two writes share a reference,
  even across two queues (a grid mounted again in the same LiveView starts a
  new one while answers for the old one may still arrive). A result that does not name the write in flight for
  its event is ignored, so a stale failure can never revert a later edit.
  """

  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.QueuedWrite

  defstruct chains: %{}, holds: %{}, elsewhere: %{}

  @typedoc "Identifies the event a chain of writes belongs to."
  @type key :: {integer() | nil, String.t()}

  @typedoc "Identifies one write: its event and its place in the queue's writes."
  @type ref :: {key(), pos_integer()}

  @typedoc "How a write answered."
  @type outcome :: {:ok, map()} | :unchanged | :queued | :failed

  @typedoc "One write, as the queue keeps it."
  @type write :: map()

  @type effect ::
          {:start, write(), map()}
          | {:show, map()}
          | :reload
          | {:notify, map(), map(), atom()}
          | {:dropped, :series_write | :series_move, pos_integer()}

  @type t :: %__MODULE__{chains: map(), holds: map(), elsewhere: map()}

  @typedoc """
  The event as another driver's writes left it: the event as last accepted,
  `:series_changed` after a write to its whole series, or `:unknown`.
  """
  @type left :: {:ok, map()} | :series_changed | :unknown

  @typedoc "Another driver finished with an event: `{driver, key, left}`."
  @type release :: {pid(), key(), left()}

  @doc "An empty queue."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Queues a write of `changes` to `event` through
  `Tymeslot.CalendarGrid.update_event/4`. `notify`, when given, is
  `%{original: event, saved_message: message}`: once the write is accepted
  the queue asks the driver to tell the attendees (`{:notify, ...}`).
  """
  @spec update(t(), map(), map(), keyword(), map() | nil) :: {t(), [effect()]}
  def update(queue, event, changes, opts, notify \\ nil),
    do:
      run(
        queue,
        &submit(&1, event, %{kind: :update, changes: changes, opts: opts, notify: notify})
      )

  @doc """
  Queues a change of the video of `event` through
  `Tymeslot.CalendarGrid.change_event_video/3`.
  """
  @spec change_video(t(), map(), pos_integer() | nil) :: {t(), [effect()]}
  def change_video(queue, event, video_integration_id),
    do:
      run(queue, &submit(&1, event, %{kind: :video, video_integration_id: video_integration_id}))

  @doc """
  Records how the write `ref` answered and starts the next write waiting for
  the same event. A result for a write that is not in flight is ignored.
  """
  @spec settle(t(), ref(), outcome()) :: {t(), [effect()]}
  def settle(queue, {key, _seq} = ref, outcome) do
    case queue.chains do
      %{^key => %{in_flight: %{ref: ^ref} = write} = chain} ->
        run(queue, &(&1 |> advance(key, chain, outcome) |> notified(write, outcome)))

      _stale ->
        {queue, []}
    end
  end

  @doc """
  Holds every write to an event of the series `event` belongs to while the
  series moves to another calendar, until `series_moved/2` or
  `series_move_failed/2`.
  """
  @spec series_moving(t(), map()) :: t()
  def series_moving(queue, event) do
    case series_key(event) do
      nil -> queue
      series -> put_hold(queue, series, %{uid: nil, held: []})
    end
  end

  @doc """
  Drops every write held while the series `event` belongs to was moving,
  once it has moved, and reloads.
  """
  @spec series_moved(t(), map()) :: {t(), [effect()]}
  def series_moved(queue, event) do
    run(queue, fn acc ->
      {held, acc} = take_hold(acc, series_key(event))
      acc |> dropped(:series_move, length(held)) |> emit(:reload)
    end)
  end

  @doc """
  Starts the writes held while the series `event` belongs to was moving,
  once the move has failed and left the series where it was.
  """
  @spec series_move_failed(t(), map()) :: {t(), [effect()]}
  def series_move_failed(queue, event), do: run(queue, &release(&1, series_key(event)))

  @doc """
  Whether a write to an event of the series `event` belongs to is still
  running or waiting, or the series is moving.
  """
  @spec series_saving?(t(), map()) :: boolean()
  def series_saving?(queue, event) do
    case series_key(event) do
      nil ->
        false

      series ->
        Map.has_key?(queue.holds, series) or
          Enum.any?(queue.chains, fn {_key, chain} -> chain.series == series end)
    end
  end

  @doc """
  Whether a write to another event of the series `event` belongs to is still
  running or waiting, or the series is moving. Writes to `event` itself are
  not counted, since a write to the whole series made from it waits behind
  them.
  """
  @spec series_busy?(t(), map()) :: boolean()
  def series_busy?(queue, event) do
    case series_key(event) do
      nil ->
        false

      series ->
        uid = event.uid

        match?(%{^series => %{uid: holder}} when holder != uid, queue.holds) or
          Enum.any?(queue.chains, fn {{_integration_id, chain_uid}, chain} ->
            chain.series == series and chain_uid != uid
          end)
    end
  end

  @doc "Whether any write is running, waiting or held, here or elsewhere."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{chains: chains, holds: holds, elsewhere: elsewhere}),
    do: map_size(chains) > 0 or map_size(holds) > 0 or map_size(elsewhere) > 0

  @doc """
  The events the queue has a write for, running, waiting or held, or waits
  for elsewhere.
  """
  @spec pending_keys(t()) :: [key()]
  def pending_keys(%__MODULE__{} = queue) do
    held = for {_series, hold} <- queue.holds, {event, _write} <- hold.held, do: key(event)
    Enum.uniq(Map.keys(queue.chains) ++ Map.keys(queue.elsewhere) ++ held)
  end

  @doc """
  Waits for the events `keys` while the driver `driver` is still writing
  them: a write to one of them is kept, not started, until `driver` has
  released it (`resume/2`). An event the queue is already writing itself is
  left out.
  """
  @spec wait_elsewhere(t(), pid(), [key()]) :: t()
  def wait_elsewhere(%__MODULE__{} = queue, driver, keys) do
    elsewhere =
      keys
      |> Enum.reject(&Map.has_key?(queue.chains, &1))
      |> Enum.reduce(queue.elsewhere, fn key, elsewhere ->
        Map.update(
          elsewhere,
          key,
          %{from: MapSet.new([driver]), held: [], left: :unknown},
          &%{&1 | from: MapSet.put(&1.from, driver)}
        )
      end)

    %{queue | elsewhere: elsewhere}
  end

  @doc """
  Records that another driver has finished with an event the queue waits
  for, and once none it waits for is left, shows the event as they left it
  and starts the writes kept for it, applied to that event.
  """
  @spec resume(t(), release()) :: {t(), [effect()]}
  def resume(queue, {driver, key, left}) do
    case queue.elsewhere do
      %{^key => %{from: from} = waiting} ->
        waiting = %{waiting | from: MapSet.delete(from, driver), left: latest(waiting.left, left)}
        run(queue, &carry_on(&1, key, waiting))

      _not_waiting ->
        {queue, []}
    end
  end

  @doc """
  How the queue's writes left the event `key`, once it has none left for
  it: worked out from the queue as it was before, and the result `messages`
  that drained it.
  """
  @spec left_by(t(), key(), [{atom(), tuple()}]) :: left()
  def left_by(queue, key, messages) do
    case queue do
      %{chains: %{^key => chain}} ->
        ref = chain.in_flight.ref
        chain_left(chain, Enum.find_value(messages, &settling(&1, ref)))

      %{elsewhere: %{^key => waiting}} ->
        for {:event_writes_released, {_driver, ^key, left}} <- messages,
            reduce: waiting.left,
            do: (acc -> latest(acc, left))

      _not_pending ->
        :unknown
    end
  end

  @doc """
  Whether the queue still waits for the write result `{tag, result}`, for
  the answer of a whole-series move, `{:event_move_result, result}`, or for
  another driver to release an event, `{:event_writes_released, release}`.
  """
  @spec awaits?(t(), {atom(), tuple()}) :: boolean()
  def awaits?(queue, {:event_move_result, {_status, payload}}) do
    if payload[:series_to],
      do: Map.has_key?(queue.holds, series_key(payload[:original_event])),
      else: false
  end

  def awaits?(queue, {tag, _result} = message)
      when tag in [:event_update_result, :event_video_result] do
    {ref, _outcome} = QueuedWrite.outcome(message)
    Enum.any?(queue.chains, fn {_key, chain} -> match?(%{in_flight: %{ref: ^ref}}, chain) end)
  end

  def awaits?(queue, {:event_writes_released, {driver, key, _left}}) do
    case queue.elsewhere do
      %{^key => %{from: from}} -> MapSet.member?(from, driver)
      _not_waiting -> false
    end
  end

  def awaits?(_queue, _message), do: false

  @doc """
  Feeds a result message into the queue as the grid's handlers would: a
  write's answer settles it, a whole-series move's answer lifts its hold,
  and another driver's release resumes the writes kept for its event. Any
  other message changes nothing.
  """
  @spec apply_result(t(), {atom(), tuple()}) :: {t(), [effect()]}
  def apply_result(queue, {:event_move_result, {status, payload}} = message) do
    cond do
      not awaits?(queue, message) -> {queue, []}
      status == :ok -> series_moved(queue, payload[:original_event])
      true -> series_move_failed(queue, payload[:original_event])
    end
  end

  def apply_result(queue, {tag, _result} = message)
      when tag in [:event_update_result, :event_video_result] do
    {ref, outcome} = QueuedWrite.outcome(message)
    settle(queue, ref, outcome)
  end

  def apply_result(queue, {:event_writes_released, release}), do: resume(queue, release)

  def apply_result(queue, _message), do: {queue, []}

  # The machinery below threads `{queue, effects}`, the effects newest
  # first; `run/2` puts them in order.
  defp run(queue, fun) do
    {queue, effects} = fun.({queue, []})
    {queue, Enum.reverse(effects)}
  end

  defp emit({queue, effects}, effect), do: {queue, [effect | effects]}

  defp dropped(acc, _reason, 0), do: acc
  defp dropped(acc, reason, count), do: emit(acc, {:dropped, reason, count})

  # The series an event belongs to, as the queue holds its writes: its
  # integration and its address there, read once, when a write is made.
  defp series_key(%{calendar_integration_id: integration_id} = event) do
    case Occurrence.series_address(event) do
      {:ok, address} -> {integration_id, address}
      {:error, _unaddressable} -> nil
    end
  end

  defp series_key(_event), do: nil

  defp key(event), do: {event.calendar_integration_id, event.uid}

  defp submit({queue, effects}, event, write) do
    key = key(event)
    series = series_key(event)
    seq = System.unique_integer([:positive, :monotonic])
    write = write |> Map.put(:ref, {key, seq}) |> tag_series_wide(series)

    case {queue.elsewhere, queue.holds} do
      # See "Events another driver is writing" in the moduledoc.
      {%{^key => waiting}, _holds} ->
        put_waiting({queue, effects}, key, %{waiting | held: [{event, write} | waiting.held]})

      # See "While a whole series is written or moved" in the moduledoc.
      {_elsewhere, %{^series => %{uid: holder} = hold}} when holder != event.uid ->
        {put_hold(queue, series, %{hold | held: [{event, write} | hold.held]}), effects}

      _free ->
        enqueue({hold_for(queue, write, event), effects}, key, series, event, write)
    end
  end

  defp put_waiting({queue, effects}, key, waiting),
    do: {%{queue | elsewhere: Map.put(queue.elsewhere, key, waiting)}, effects}

  # Once no driver it waits for is left, the kept writes start from the
  # event as those drivers left it (see "Events another driver is writing").
  defp carry_on({queue, effects} = acc, key, waiting) do
    if MapSet.size(waiting.from) > 0 do
      put_waiting(acc, key, waiting)
    else
      acc = {%{queue | elsewhere: Map.delete(queue.elsewhere, key)}, effects}
      start_kept(acc, Enum.reverse(waiting.held), waiting.left)
    end
  end

  defp start_kept(acc, held, :series_changed),
    do: acc |> dropped(:series_write, length(held)) |> emit(:reload)

  defp start_kept(acc, held, {:ok, event}) do
    shown =
      Enum.reduce(held, event, fn {_made_on, write}, shown ->
        QueuedWrite.applied(shown, write)
      end)

    Enum.reduce(held, emit(acc, {:show, shown}), fn {_made_on, write}, acc ->
      submit(acc, event, write)
    end)
  end

  defp start_kept(acc, held, :unknown),
    do: Enum.reduce(held, acc, fn {event, write}, acc -> submit(acc, event, write) end)

  defp latest(left, :unknown), do: left
  defp latest(_older, left), do: left

  defp settling({tag, _result} = message, ref)
       when tag in [:event_update_result, :event_video_result] do
    case QueuedWrite.outcome(message) do
      {^ref, outcome} -> outcome
      _other -> nil
    end
  end

  defp settling(_message, _ref), do: nil

  defp chain_left(chain, nil), do: {:ok, chain.confirmed}

  defp chain_left(chain, outcome) do
    if series_wide_success?(chain.in_flight, outcome),
      do: :series_changed,
      else: {:ok, confirmed_after(chain, outcome)}
  end

  defp enqueue({queue, _effects} = acc, key, series, event, write) do
    case queue.chains do
      %{^key => chain} ->
        put_chain(acc, key, %{chain | waiting: :queue.in(write, chain.waiting)})

      _idle ->
        acc
        |> put_chain(key, %{
          confirmed: event,
          series: series,
          in_flight: write,
          waiting: :queue.new()
        })
        |> emit({:start, write, event})
    end
  end

  # A write to the whole of an addressable series carries the series, so
  # the hold it puts on it can be lifted when it answers.
  defp tag_series_wide(write, nil), do: write

  defp tag_series_wide(%{kind: :update, opts: opts} = write, series) do
    if Keyword.get(opts, :recurrence_scope) in [:following, :all],
      do: Map.put(write, :series, series),
      else: write
  end

  defp tag_series_wide(write, _series), do: write

  defp hold_for(queue, %{series: series}, event) do
    if Map.has_key?(queue.holds, series),
      do: queue,
      else: put_hold(queue, series, %{uid: event.uid, held: []})
  end

  defp hold_for(queue, _write, _event), do: queue

  defp put_hold(queue, series, hold), do: %{queue | holds: Map.put(queue.holds, series, hold)}

  # Lifts the hold on `series`, answering with the writes it held, oldest
  # first.
  defp take_hold({queue, effects} = acc, series) do
    case Map.pop(queue.holds, series) do
      {nil, _holds} -> {[], acc}
      {hold, holds} -> {Enum.reverse(hold.held), {%{queue | holds: holds}, effects}}
    end
  end

  # Lifts the hold on `series` and makes the writes it held, in order, as
  # if they had just been made.
  defp release(acc, series) do
    {held, acc} = take_hold(acc, series)
    Enum.reduce(held, acc, fn {event, write}, acc -> submit(acc, event, write) end)
  end

  # See "Telling the attendees" in `TymeslotWeb.Dashboard.CalendarGrid.EventWrites`.
  defp notified(acc, %{kind: :update, notify: %{} = notify, opts: opts}, {:ok, updated}),
    do: emit(acc, {:notify, notify, updated, Keyword.get(opts, :recurrence_scope, :this_only)})

  defp notified(acc, _write, _outcome), do: acc

  defp advance(acc, key, chain, outcome) do
    cond do
      series_wide_success?(chain.in_flight, outcome) ->
        after_series_write(acc, key, chain)

      Map.has_key?(chain.in_flight, :series) ->
        acc
        |> advance_chain(key, chain, outcome)
        |> release_unless_pending(key, chain.in_flight.series)

      true ->
        advance_chain(acc, key, chain, outcome)
    end
  end

  defp advance_chain(acc, key, chain, outcome) do
    confirmed = confirmed_after(chain, outcome)

    case :queue.out(chain.waiting) do
      {:empty, _none} ->
        acc = delete_chain(acc, key)
        if outcome == :failed, do: emit(acc, {:show, confirmed}), else: acc

      {{:value, next}, rest} ->
        acc
        |> put_chain(key, %{chain | confirmed: confirmed, in_flight: next, waiting: rest})
        |> show_waiting(outcome, confirmed, [next | :queue.to_list(rest)])
        |> emit({:start, next, confirmed})
    end
  end

  # A write to the whole series that did not change it lifts its hold,
  # unless another one made from the same event is still to run.
  defp release_unless_pending({queue, _effects} = acc, key, series) do
    pending =
      case queue.chains do
        %{^key => chain} -> [chain.in_flight | :queue.to_list(chain.waiting)]
        _drained -> []
      end

    if Enum.any?(pending, &(Map.get(&1, :series) == series)),
      do: acc,
      else: release(acc, series)
  end

  defp series_wide_success?(%{kind: :update, opts: opts}, {:ok, _updated}),
    do: Keyword.get(opts, :recurrence_scope) in [:following, :all]

  defp series_wide_success?(_write, _outcome), do: false

  # See "After a write to a whole series" in the moduledoc.
  defp after_series_write(acc, key, chain) do
    {held, acc} = take_hold(acc, Map.get(chain.in_flight, :series))

    acc
    |> dropped(:series_write, :queue.len(chain.waiting) + length(held))
    |> delete_chain(key)
    |> emit(:reload)
  end

  defp confirmed_after(_chain, {:ok, updated}), do: updated
  defp confirmed_after(chain, :queued), do: QueuedWrite.applied(chain.confirmed, chain.in_flight)
  defp confirmed_after(chain, _unchanged_or_failed), do: chain.confirmed

  # A failure takes only its own change back: the writes still waiting keep
  # theirs on screen, since they are about to be written.
  defp show_waiting(acc, :failed, confirmed, waiting),
    do: emit(acc, {:show, Enum.reduce(waiting, confirmed, &QueuedWrite.applied(&2, &1))})

  defp show_waiting(acc, _accepted, _confirmed, _waiting), do: acc

  defp put_chain({queue, effects}, key, chain),
    do: {%{queue | chains: Map.put(queue.chains, key, chain)}, effects}

  defp delete_chain({queue, effects}, key),
    do: {%{queue | chains: Map.delete(queue.chains, key)}, effects}
end
