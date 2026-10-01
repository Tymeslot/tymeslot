defmodule Tymeslot.CalendarGrid.WriteGuardian do
  @moduledoc """
  Sees the calendar grid's queued edits through to the provider when the
  grid's LiveView is gone before they have started.

  The grid shows every edit at once and writes it in the background, one
  write in flight per event, the rest waiting in a
  `Tymeslot.CalendarGrid.WriteQueue` held by the LiveView. A running write
  outlives the LiveView, but a waiting or held one lives only in its state:
  if the tab closes, the organiser navigates away or the process crashes,
  it would never be written, although the organiser saw it made.

  So each LiveView that has queued a write has one guardian, registered
  under the LiveView's pid. The LiveView sends it the queue after every
  change (`mirror/2`), before any write it starts, and every write's task,
  and a whole-series move's, sends its result here as well as to the
  LiveView. While the LiveView lives, the guardian only keeps the latest
  queue, and the results that queue still waits for.

  When the LiveView goes down, or the grid is taken off the page while the
  LiveView lives on (`detach/0`), the guardian drives the queue itself: it
  settles the results it already holds and every later one with the same
  `WriteQueue` functions, starts the writes they release, and ignores what
  is only for the screen. A waiting write is applied to the event as the
  write before it left it, so it is started only once that write has
  answered, exactly as the grid would have done; an edit the provider could
  not take is saved for offline retry by
  `Tymeslot.CalendarGrid.update_event/4` as usual.

  A grid mounted again in the same LiveView takes the queue back
  (`adopt/2`), so that its new edits wait behind the ones still being
  written; until then, and after, each write's result goes to the LiveView
  as well. A guardian whose LiveView is gone stops once the queue is empty.

  ## A LiveView mounted again

  When the connection drops and comes back (common on a phone), the grid is
  mounted in a new LiveView while the old one's guardian may still be
  writing its queue. Left to itself, an older edit it writes could land
  after a newer edit of the same event made in the new grid. So `adopt/2`
  also takes over the queue of every guardian of the same organiser whose
  LiveView is gone, merging it into the new grid's (`WriteQueue.merge/2`),
  and the new grid's edits wait behind its writes. A guardian whose
  LiveView still lives, another tab, is never taken.

  The guardian taken over writes nothing more. It stays registered under
  its old LiveView, which its running writes still report to, and passes
  each of their results on to the new LiveView (`report/2`), stopping once
  the last has answered. Write references are unique on the node, so the
  merged queues never confuse one write's answer for another's.

  Should the queue never be driven to its end, because the node is stopping
  or the provider has not answered for `:drain_timeout`, the guardian saves
  what it can for the next sync (`WriteQueue.hand_over/1`,
  `Tymeslot.CalendarGrid.EventEdit.queue_for_retry/4`) and logs, at error
  level, how many writes it could not.
  """

  # Long enough on shutdown to save what is still queued for a later sync.
  use GenServer, restart: :temporary, shutdown: 15_000

  require Logger

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks

  @registry Tymeslot.CalendarGrid.WriteGuardianRegistry
  @user_registry Tymeslot.CalendarGrid.WriteGuardianUserRegistry
  @supervisor Tymeslot.CalendarGrid.WriteGuardians

  # How long a guardian left driving waits for a write to answer before it
  # gives up on what is still queued. Well beyond any provider timeout.
  @drain_timeout Application.compile_env(
                   :tymeslot,
                   [__MODULE__, :drain_timeout],
                   :timer.minutes(10)
                 )

  @result_tags [:event_update_result, :event_video_result, :event_move_result]

  @doc "The name of the Registry guardians register in."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The name of the Registry guardians register in under their user's id."
  @spec user_registry() :: atom()
  def user_registry, do: @user_registry

  @doc "The name of the DynamicSupervisor guardians run under."
  @spec supervisor() :: atom()
  def supervisor, do: @supervisor

  @doc false
  @spec start_link({pid(), pos_integer(), [pid()]}) :: GenServer.on_start()
  def start_link({owner, _user_id, _callers} = args),
    do: GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, owner}})

  @doc """
  Gives the calling LiveView's guardian `queue`, starting one for `user_id`
  when the queue has writes and there is none yet.
  """
  @spec mirror(WriteQueue.t(), pos_integer()) :: :ok
  def mirror(queue, user_id) do
    case whereis(self()) || (WriteQueue.pending?(queue) && start(user_id)) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:mirror, queue})
      _none -> :ok
    end
  end

  @doc """
  Hands the writes still queued by the calling LiveView to its guardian to
  drive on its own, because the grid that queued them is gone while the
  LiveView lives on. The guardian stays registered, so a grid mounted again
  takes them back with `adopt/0`. A no-op when there is no guardian.
  """
  @spec detach() :: :ok
  def detach do
    case whereis(self()) do
      nil -> :ok
      pid -> call(pid, :detach, :ok)
    end
  end

  @doc """
  The queue a grid mounting in the calling LiveView for `user_id` starts
  from, so that a new edit of an event still being written waits behind it:
  the queue the LiveView's own guardian holds, for a grid mounted again
  after `detach/0`, or else `queue`; merged with the queue of every guardian
  of `user_id` whose LiveView is gone (see "A LiveView mounted again"). The
  LiveView's own guardian goes back to only mirroring the queue.

  Called inside the LiveView, so the result of any write that arrives before
  the grid has its queue waits in the LiveView's mailbox, and is settled
  against the queue once the grid has it: a result a guardian already
  settled no longer names a write in flight, and is ignored.
  """
  @spec adopt(WriteQueue.t(), pos_integer()) :: WriteQueue.t()
  def adopt(queue, user_id) do
    own = whereis(self())
    queue = (own && call(own, :adopt, nil)) || queue

    for {pid, _value} <- Registry.lookup(@user_registry, user_id),
        pid != own,
        reduce: queue do
      queue ->
        case call(pid, {:take_over, self(), queue}, :refused) do
          {:ok, merged} -> merged
          :refused -> queue
        end
    end
  end

  @doc """
  Sends a write's result `message` to the guardian of the LiveView `owner`,
  looked up now, and then to `owner`. Looked up at send time rather than
  when the write started, so a guardian started since, after one crashed,
  still hears it.
  """
  @spec report(pid(), {atom(), tuple()}) :: :ok
  def report(owner, message) do
    if guardian = whereis(owner), do: send(guardian, message)
    send(owner, message)
    :ok
  end

  @doc "The guardian of the LiveView `owner`, if it has one."
  @spec whereis(pid()) :: pid() | nil
  def whereis(owner) do
    case Registry.lookup(@registry, owner) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  # A guardian that has just stopped, having nothing left to do, answers
  # as if there were none.
  defp call(pid, request, none) do
    GenServer.call(pid, request)
  catch
    :exit, _stopped -> none
  end

  defp start(user_id) do
    # The caller's `$callers` carry on to the writes the guardian starts,
    # as they do for the LiveView's own tasks.
    callers = [self() | Process.get(:"$callers", [])]

    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {self(), user_id, callers}}) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Logger.error("Calendar grid write guardian failed to start",
          reason: LogFormat.reason(reason)
        )

        nil
    end
  end

  @impl GenServer
  def init({owner, user_id, callers}) do
    # So that a shutdown runs `terminate/2`, which saves what it can.
    Process.flag(:trap_exit, true)
    Process.put(:"$callers", callers)
    {:ok, _owner} = Registry.register(@user_registry, user_id, nil)

    {:ok,
     %{
       owner: owner,
       owner_alive?: true,
       monitor: Process.monitor(owner),
       user_id: user_id,
       queue: WriteQueue.new(),
       results: [],
       driving?: false,
       # Once taken over: the LiveView its writes' results go on to, and
       # what of its queue is still running.
       taken_by: nil,
       running: nil
     }}
  end

  @impl GenServer
  def handle_cast({:mirror, queue}, %{driving?: false} = state) do
    results = Enum.filter(state.results, &WriteQueue.awaits?(queue, &1))
    {:noreply, %{state | queue: queue, results: results}}
  end

  def handle_cast({:mirror, _queue}, state), do: {:noreply, state, @drain_timeout}

  @impl GenServer
  def handle_call(:detach, from, state) do
    GenServer.reply(from, :ok)
    drive(state)
  end

  def handle_call(:adopt, _from, state),
    do: {:reply, state.queue, %{state | driving?: false}}

  # Taken over only by a LiveView of the same organiser (see `adopt/2`), and
  # only once its own LiveView is gone; asked before its `:DOWN` is handled,
  # it answers by whether the LiveView lives now.
  def handle_call({:take_over, new_owner, queue}, _from, %{taken_by: nil} = state) do
    with false <- Process.alive?(state.owner),
         {:ok, merged} <- WriteQueue.merge(queue, state.queue) do
      state |> taken_over(new_owner) |> forwarding({:ok, merged})
    else
      _owner_alive_or_conflict -> {:reply, :refused, state, timeout(state)}
    end
  end

  def handle_call({:take_over, _new_owner, _queue}, _from, state),
    do: {:reply, :refused, state, timeout(state)}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{monitor: ref} = state),
    do: drive(%{state | owner_alive?: false})

  def handle_info({tag, _result} = message, %{taken_by: pid} = state)
      when is_pid(pid) and tag in @result_tags do
    state |> forward(message) |> forwarding()
  end

  def handle_info({tag, _result} = message, %{driving?: false} = state)
      when tag in @result_tags do
    if WriteQueue.awaits?(state.queue, message),
      do: {:noreply, %{state | results: state.results ++ [message]}},
      else: {:noreply, state}
  end

  def handle_info({tag, _result} = message, state) when tag in @result_tags do
    state |> apply_result(message) |> continue()
  end

  # `terminate/2` saves what it can.
  def handle_info(:timeout, %{driving?: true} = state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # The queue will not be driven to its end: the node is stopping, or the
  # provider never answered. What can be is saved for a later sync; what
  # cannot is logged, since the organiser saw it made.
  @impl GenServer
  def terminate(_reason, state) do
    if WriteQueue.pending?(state.queue), do: hand_over(state)
    :ok
  end

  defp hand_over(state) do
    {plans, lost} = WriteQueue.hand_over(state.queue)
    unsaved = lost + Enum.sum(Enum.map(plans, &save(&1, state.user_id)))

    if unsaved > 0 do
      Logger.error("Calendar grid writes lost: the grid's queue could not be finished",
        user_id: state.user_id,
        lost_writes: unsaved
      )
    end
  end

  # Saves each write in turn onto the event as the one before left it, the
  # last carrying all of them; answers how many could not be saved.
  defp save({event, writes}, user_id) do
    writes
    |> Enum.reduce_while({event, length(writes)}, fn write, {event, unsaved} ->
      case EventEdit.queue_for_retry(user_id, event, write.changes, write.opts) do
        {:ok, updated} -> {:cont, {updated, unsaved - 1}}
        {:error, :not_queued} -> {:halt, {event, unsaved}}
      end
    end)
    |> elem(1)
  rescue
    error ->
      Logger.error("Calendar grid writes could not be saved for a later sync",
        user_id: user_id,
        error: Exception.message(error)
      )

      length(writes)
  end

  # Hands the queue on: from now on it writes nothing, and only passes on
  # the results of the writes it has running, including any it already
  # holds, to the LiveView that took it over.
  defp taken_over(state, new_owner) do
    Process.demonitor(state.monitor, [:flush])
    Registry.unregister(@user_registry, state.user_id)

    Enum.reduce(
      state.results,
      %{
        state
        | queue: WriteQueue.new(),
          results: [],
          driving?: true,
          taken_by: new_owner,
          running: WriteQueue.running(state.queue)
      },
      &forward(&2, &1)
    )
  end

  defp forward(state, message) do
    if WriteQueue.awaits?(state.running, message) do
      report(state.taken_by, message)
      {running, _effects} = WriteQueue.apply_result(state.running, message)
      %{state | running: running}
    else
      state
    end
  end

  # Stops once every write it had running has answered.
  defp forwarding(state, reply \\ nil) do
    case {WriteQueue.pending?(state.running), reply} do
      {true, nil} -> {:noreply, state, @drain_timeout}
      {true, reply} -> {:reply, reply, state, @drain_timeout}
      {false, nil} -> {:stop, :normal, state}
      {false, reply} -> {:stop, :normal, reply, state}
    end
  end

  defp timeout(%{driving?: true}), do: @drain_timeout
  defp timeout(_mirroring), do: :infinity

  # Takes the queue over from the grid: settles the results already in
  # hand, oldest first, then waits for the rest.
  defp drive(state) do
    state = %{state | driving?: true}

    state.results
    |> Enum.reduce(%{state | results: []}, &apply_result(&2, &1))
    |> continue()
  end

  # Once the queue is empty, a guardian whose LiveView lives on goes back to
  # mirroring, for the grid it may mount again; one whose LiveView is gone
  # stops.
  defp continue(state) do
    cond do
      WriteQueue.pending?(state.queue) -> {:noreply, state, @drain_timeout}
      state.owner_alive? -> {:noreply, %{state | driving?: false}}
      true -> {:stop, :normal, state}
    end
  end

  defp apply_result(state, message) do
    {queue, effects} = WriteQueue.apply_result(state.queue, message)
    Enum.each(effects, &start_write(&1, state))
    %{state | queue: queue}
  end

  # Only a write reaches the provider; what else the queue asks for is for
  # a screen there no longer is. The result goes to the LiveView as well,
  # as its own writes' do, for a grid it mounts again.
  defp start_write({:start, write, event}, %{owner: owner, user_id: user_id}) do
    tag = WriteQueue.result_tag(write)

    {:ok, _pid} =
      Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
        report(owner, {tag, WriteQueue.perform(user_id, write, event)})
      end)

    :ok
  end

  defp start_write(_screen_effect, _state), do: :ok
end
