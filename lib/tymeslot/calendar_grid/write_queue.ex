defmodule Tymeslot.CalendarGrid.WriteQueue do
  @moduledoc """
  The order in which the calendar grid writes its edits of existing events,
  as plain data, so that whichever process drives it (the grid's LiveView,
  or `Tymeslot.CalendarGrid.WriteGuardian` once the LiveView is gone) makes
  exactly the same writes in exactly the same order.

  Every function that changes the queue answers `{queue, effects}`. The
  effects are what the driver must do, in order:

    * `{:start, write, event}`: start `write` against `event` (see
      `perform/3`), and hand its result back to `settle/3`;
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

  ## References

  Every write carries a reference, `{key, seq}`, where `seq` rises with every
  write taken by any queue on the node, so no two writes share a reference,
  even across two queues (a grid mounted again in the same LiveView starts a
  new one while answers for the old one may still arrive). A result that does not name the write in flight for
  its event is ignored, so a stale failure can never revert a later edit.
  """

  require Logger

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Infrastructure.Logging.LogFormat

  defstruct chains: %{}, holds: %{}

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

  @type t :: %__MODULE__{chains: map(), holds: map()}

  @typedoc "The message a write's task answers with, as `{tag, result}`."
  @type result :: {:event_update_result | :event_video_result, tuple()}

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

  @doc "Whether any write is running, waiting or held."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{chains: chains, holds: holds}),
    do: map_size(chains) > 0 or map_size(holds) > 0

  @doc "How many writes are running, waiting or held."
  @spec pending_count(t()) :: non_neg_integer()
  def pending_count(%__MODULE__{chains: chains, holds: holds}) do
    queued = Enum.reduce(chains, 0, fn {_key, chain}, n -> n + 1 + :queue.len(chain.waiting) end)
    Enum.reduce(holds, queued, fn {_series, hold}, n -> n + length(hold.held) end)
  end

  @doc """
  What can still be saved for a later sync when the queue will never be
  driven to its end (the node is stopping, or the provider never answered):
  for each event, the event as its running write would leave it, with the
  writes waiting behind it that can be made from that, oldest first; and how
  many writes cannot be.

  A waiting edit of the event's fields can: it is applied to the confirmed
  event with the running write's change taken as made, as an edit saved to
  sync later would be. A video change cannot, nor anything behind it, since
  what it writes is only known once the video provider has answered; nor a
  write to a whole series, or anything waiting behind one or held by one,
  since whether it may still be made depends on how the series write ends.
  """
  @spec hand_over(t()) :: {[{map(), [write()]}], non_neg_integer()}
  def hand_over(%__MODULE__{chains: chains, holds: holds}) do
    held = Enum.reduce(holds, 0, fn {_series, hold}, n -> n + length(hold.held) end)

    Enum.reduce(chains, {[], held}, fn {_key, chain}, {plans, lost} ->
      waiting = :queue.to_list(chain.waiting)

      if plain_edit?(chain.in_flight) do
        {ready, rest} = Enum.split_while(waiting, &plain_edit?/1)

        plans =
          if ready == [],
            do: plans,
            else: [{with_change(chain.confirmed, chain.in_flight), ready} | plans]

        {plans, lost + length(rest)}
      else
        {plans, lost + length(waiting)}
      end
    end)
  end

  defp plain_edit?(%{kind: :update, opts: opts} = write),
    do:
      not Map.has_key?(write, :series) and
        Keyword.get(opts, :recurrence_scope) not in [:following, :all]

  defp plain_edit?(_write), do: false

  @doc """
  Whether the queue still waits for the write result `{tag, result}`, or
  for the answer of a whole-series move, `{:event_move_result, result}`.
  """
  @spec awaits?(t(), {atom(), tuple()}) :: boolean()
  def awaits?(queue, {:event_move_result, {_status, payload}}) do
    if payload[:series_to],
      do: Map.has_key?(queue.holds, series_key(payload[:original_event])),
      else: false
  end

  def awaits?(queue, {tag, _result} = message)
      when tag in [:event_update_result, :event_video_result] do
    {ref, _outcome} = outcome(message)
    Enum.any?(queue.chains, fn {_key, chain} -> match?(%{in_flight: %{ref: ^ref}}, chain) end)
  end

  def awaits?(_queue, _message), do: false

  @doc """
  Feeds a result message into the queue as the grid's handlers would: a
  write's answer settles it, and a whole-series move's answer lifts its
  hold. Any other message changes nothing.
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
    {ref, outcome} = outcome(message)
    settle(queue, ref, outcome)
  end

  def apply_result(queue, _message), do: {queue, []}

  @doc """
  The write a result message answers, and how it answered: a success, a
  video choice that changed nothing, an edit saved to sync later, or a
  failure.
  """
  @spec outcome(result()) :: {ref(), outcome()}
  def outcome({:event_update_result, {:ok, payload}}),
    do: {payload[:write], {:ok, payload[:updated_event]}}

  def outcome({:event_update_result, {:error, payload}}),
    do: {payload[:write], if(payload[:retry] == :queued, do: :queued, else: :failed)}

  def outcome({:event_video_result, {:unchanged, payload}}), do: {payload[:write], :unchanged}

  def outcome({:event_video_result, {:ok, payload}}),
    do: {payload[:write], {:ok, payload[:updated_event]}}

  def outcome({:event_video_result, {:error, payload}}), do: {payload[:write], :failed}

  @doc "The tag the result of `write` is sent under."
  @spec result_tag(write()) :: :event_update_result | :event_video_result
  def result_tag(%{kind: :update}), do: :event_update_result
  def result_tag(%{kind: :video}), do: :event_video_result

  @doc """
  Makes `write` against `event` for `user_id` and answers with its result
  message, never raising: a crash answers as a failure.

  An update answers `{:ok, write: ref, updated_event: event}` or `{:error,
  write: ref, original_event: event, reason: reason, retry: retry}`, where
  `retry` is `:queued` when the edit is saved locally and will sync. A video
  change answers `{:ok, write: ref, original_event: event, updated_event:
  event}`, `{:unchanged, write: ref}`, or `{:error, write: ref,
  original_event: event, reason: reason}`.
  """
  @spec perform(pos_integer(), write(), map()) :: tuple()
  def perform(user_id, write, event) do
    do_perform(user_id, write, event)
  catch
    kind, reason ->
      Logger.error("Calendar grid write crashed",
        write_kind: write.kind,
        kind: kind,
        error: LogFormat.reason(reason),
        stacktrace: LogFormat.stacktrace(__STACKTRACE__)
      )

      crash_result(write, event)
  end

  @doc "The result `write` answers with when it crashes."
  @spec crash_result(write(), map()) :: tuple()
  def crash_result(%{kind: :update, ref: ref}, event),
    do: update_failure(ref, event, :crashed, :not_queued)

  def crash_result(%{kind: :video, ref: ref}, event), do: video_failure(ref, event, :crashed)

  defp do_perform(user_id, %{kind: :update, ref: ref} = write, event) do
    case CalendarGrid.update_event(user_id, event, write.changes, write.opts) do
      {:ok, updated} -> {:ok, write: ref, updated_event: updated}
      {:error, %{reason: reason, retry: retry}} -> update_failure(ref, event, reason, retry)
    end
  end

  defp do_perform(user_id, %{kind: :video, ref: ref, video_integration_id: video_id}, event) do
    case CalendarGrid.change_event_video(user_id, event, video_id) do
      {:ok, :unchanged} ->
        {:unchanged, write: ref}

      # The event as the change wrote it, so the grid shows what the
      # calendar has and the notification diff sees exactly what the
      # attendees' invitation will carry.
      {:ok, url} ->
        {:ok,
         write: ref,
         original_event: event,
         updated_event: CalendarGrid.changed_event(user_id, event, video_id, url)}

      {:error, reason} ->
        video_failure(ref, event, reason)
    end
  end

  defp update_failure(ref, event, reason, retry),
    do: {:error, write: ref, original_event: event, reason: reason, retry: retry}

  defp video_failure(ref, event, reason),
    do: {:error, write: ref, original_event: event, reason: reason}

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

  defp submit({queue, effects}, event, write) do
    key = {event.calendar_integration_id, event.uid}
    series = series_key(event)
    seq = System.unique_integer([:positive, :monotonic])
    write = write |> Map.put(:ref, {key, seq}) |> tag_series_wide(series)

    case queue.holds do
      # See "While a whole series is written or moved" in the moduledoc.
      %{^series => %{uid: holder} = hold} when holder != event.uid ->
        {put_hold(queue, series, %{hold | held: [{event, write} | hold.held]}), effects}

      _free ->
        enqueue({hold_for(queue, write, event), effects}, key, series, event, write)
    end
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
  defp confirmed_after(chain, :queued), do: with_change(chain.confirmed, chain.in_flight)
  defp confirmed_after(chain, _unchanged_or_failed), do: chain.confirmed

  # A failure takes only its own change back: the writes still waiting keep
  # theirs on screen, since they are about to be written.
  defp show_waiting(acc, :failed, confirmed, waiting),
    do: emit(acc, {:show, Enum.reduce(waiting, confirmed, &with_change(&2, &1))})

  defp show_waiting(acc, _accepted, _confirmed, _waiting), do: acc

  defp with_change(event, %{kind: :update, changes: changes}), do: Map.merge(event, changes)

  defp with_change(event, %{kind: :video, video_integration_id: id}),
    do: Map.put(event, :video_integration_id, id)

  defp put_chain({queue, effects}, key, chain),
    do: {%{queue | chains: Map.put(queue.chains, key, chain)}, effects}

  defp delete_chain({queue, effects}, key),
    do: {%{queue | chains: Map.delete(queue.chains, key)}, effects}
end
