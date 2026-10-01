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

  ## A grid mounted in another LiveView

  When the connection drops and comes back (common on a phone), the grid is
  mounted in a new LiveView while the old one may still be writing its
  queue: the server often notices the dead connection only at the
  heartbeat timeout, and until then the old LiveView lives and drives its
  queue as before, its guardian taking over once it is gone. Another tab of
  the same organiser does the same. Either way, a write to an event the
  other is still writing would race it, and since every write sends the
  whole event, an older edit landing last would undo the newer one.

  So `adopt/2` asks every other guardian of the organiser which events it
  has writes for, and the new grid's queue waits for those
  (`WriteQueue.wait_elsewhere/2`). Nothing is taken from the other
  guardian, which may belong to a tab still open: it, or its LiveView while
  that lives, goes on driving its own queue to the end. It only lends the
  event: once its queue has no write left for it, it releases the event to
  each grid that waits for it (`{:event_writes_released, release}`, sent as
  `report/2` sends a write's result), with the event as its writes left it,
  and the waiting grid's own writes start from that. Who drives the older
  writes therefore never changes hands, and nothing depends on which of two
  `:DOWN` messages arrives first. A guardian saves what it can when it
  stops, and releases every event it still lends on the way out.

  A guardian killed outright (a brutal kill once its shutdown time is up,
  or by hand) runs no `terminate/2` and releases nothing. So a guardian
  that lends events tells the waiting grid's guardian which ones, and that
  guardian monitors it and keeps track of the events it still owes: should
  the lender die owing any, it releases them itself, as `:unknown`, both to
  itself and to its LiveView, and the grid's kept edits start.

  Should the queue never be driven to its end, because the node is stopping
  or the provider has not answered for `:drain_timeout`, the guardian saves
  what it can for the next sync (`Tymeslot.CalendarGrid.WriteHandOver`).
  """

  # Long enough on shutdown to save what is still queued for a later sync.
  use GenServer, restart: :temporary, shutdown: 15_000

  require Logger

  alias Tymeslot.CalendarGrid.QueuedWrite
  alias Tymeslot.CalendarGrid.WriteHandOver
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

  @result_tags [
    :event_update_result,
    :event_video_result,
    :event_move_result,
    :event_writes_released
  ]

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
  after `detach/0`, or else `queue`; waiting for every event another
  guardian of `user_id` still has writes for (see "A grid mounted in
  another LiveView"). The LiveView's own guardian goes back to only
  mirroring the queue.

  Called inside the LiveView, so the result of any write that arrives before
  the grid has its queue waits in the LiveView's mailbox, and is settled
  against the queue once the grid has it: a result a guardian already
  settled no longer names a write in flight, and is ignored.
  """
  @spec adopt(WriteQueue.t(), pos_integer()) :: WriteQueue.t()
  def adopt(queue, user_id) do
    own = whereis(self())
    queue = (own && call(own, :adopt, nil)) || queue

    case for({pid, _value} <- Registry.lookup(@user_registry, user_id), pid != own, do: pid) do
      [] ->
        queue

      lenders ->
        # Started before any event is lent, so that it hears every release.
        _guardian = own || start(user_id)

        WriteQueue.wait_elsewhere(
          queue,
          for(lender <- lenders, do: {lender, call(lender, {:lend, self()}, [])})
        )
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
       # The LiveViews waiting for each event lent to them, by its key.
       lent: %{},
       # The events lent to this guardian's LiveView that each lender, by
       # its pid, has not released yet.
       owed: %{}
     }}
  end

  @impl GenServer
  def handle_cast({:mirror, queue}, %{driving?: false} = state) do
    state = release_drained(%{state | queue: queue}, state.queue, state.results)
    results = Enum.filter(state.results, &WriteQueue.awaits?(queue, &1))
    {:noreply, %{state | results: results}}
  end

  def handle_cast({:mirror, _queue}, state), do: {:noreply, state, @drain_timeout}

  @impl GenServer
  def handle_call(:detach, from, state) do
    GenServer.reply(from, :ok)
    drive(state)
  end

  def handle_call(:adopt, _from, state),
    do: {:reply, state.queue, %{state | driving?: false}}

  # See "A grid mounted in another LiveView" in the moduledoc.
  def handle_call({:lend, borrower}, _from, state) do
    keys = WriteQueue.pending_keys(state.queue)

    lent =
      Enum.reduce(keys, state.lent, &Map.update(&2, &1, [borrower], fn bs -> [borrower | bs] end))

    # Sent from here, ahead of any release of these events, so that the
    # borrower's guardian always hears of a lend before its release.
    guardian = keys != [] && whereis(borrower)
    if guardian, do: send(guardian, {:event_writes_lent, self(), keys})

    {:reply, keys, %{state | lent: lent}, timeout(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{monitor: ref} = state),
    do: drive(%{state | owner_alive?: false})

  # A lender's messages all arrive before its `:DOWN`, so the events it
  # still owes here are those it never released: it was killed outright.
  # Each is released as a lender would release it, with the event left
  # `:unknown`, so the kept edits start from the event they were made on.
  #
  # What this cannot cover: a write the lender had in flight runs on in an
  # unlinked task, whose result goes to the lender's LiveView, so it may
  # still land after the kept edits, and nothing here can know when it
  # has; nor would stopping the task help, since a request already sent may
  # still be applied. Equally, when only the guardian was killed and its
  # LiveView lives on, that LiveView goes on writing its own queue.
  def handle_info({:DOWN, _ref, :process, lender, _reason}, state)
      when is_map_key(state.owed, lender) do
    {keys, owed} = Map.pop(state.owed, lender)

    for key <- keys do
      release = {:event_writes_released, {lender, key, :unknown}}
      send(self(), release)
      if state.owner_alive?, do: send(state.owner, release)
    end

    {:noreply, %{state | owed: owed}, timeout(state)}
  end

  def handle_info({:event_writes_lent, lender, keys}, state) do
    if not Map.has_key?(state.owed, lender), do: Process.monitor(lender)
    owed = Map.update(state.owed, lender, MapSet.new(keys), &MapSet.union(&1, MapSet.new(keys)))
    {:noreply, %{state | owed: owed}, timeout(state)}
  end

  def handle_info({tag, _result} = message, state) when tag in @result_tags do
    state = forget_owed(state, message)

    cond do
      state.driving? ->
        state |> apply_result(message) |> continue()

      # A release is kept even before the queue waiting for it has arrived,
      # since a guardian may lend the event as soon as `adopt/2` has asked.
      tag == :event_writes_released or WriteQueue.awaits?(state.queue, message) ->
        {:noreply, %{state | results: state.results ++ [message]}}

      true ->
        {:noreply, state}
    end
  end

  # `terminate/2` saves what it can.
  def handle_info(:timeout, %{driving?: true} = state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # The queue will not be driven to its end: the node is stopping, or the
  # provider never answered. What can be is saved for a later sync; what
  # cannot is logged, since the organiser saw it made.
  @impl GenServer
  def terminate(_reason, state) do
    if WriteQueue.pending?(state.queue), do: WriteHandOver.save(state.queue, state.user_id)
    release_drained(%{state | queue: WriteQueue.new()}, state.queue, [])
    :ok
  end

  # Releases every event lent that the queue no longer has a write for, with
  # the event as `old_queue` and the `messages` that drained it left it.
  defp release_drained(%{lent: lent} = state, _old_queue, _messages) when lent == %{},
    do: state

  defp release_drained(state, old_queue, messages) do
    pending = WriteQueue.pending_keys(state.queue)
    {drained, lent} = Map.split_with(state.lent, fn {key, _borrowers} -> key not in pending end)

    for {key, borrowers} <- drained, borrower <- borrowers do
      left = WriteQueue.left_by(old_queue, key, messages)
      report(borrower, {:event_writes_released, {self(), key, left}})
    end

    %{state | lent: lent}
  end

  defp forget_owed(state, {:event_writes_released, {lender, key, _left}}) do
    case state.owed do
      %{^lender => keys} -> %{state | owed: %{state.owed | lender => MapSet.delete(keys, key)}}
      _not_owed -> state
    end
  end

  defp forget_owed(state, _result), do: state

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
    release_drained(%{state | queue: queue}, state.queue, [message])
  end

  # Only a write reaches the provider; what else the queue asks for is for
  # a screen there no longer is. The result goes to the LiveView as well,
  # as its own writes' do, for a grid it mounts again.
  defp start_write({:start, write, event}, %{owner: owner, user_id: user_id}) do
    tag = QueuedWrite.result_tag(write)

    {:ok, _pid} =
      Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
        report(owner, {tag, QueuedWrite.perform(user_id, write, event)})
      end)

    :ok
  end

  defp start_write(_screen_effect, _state), do: :ok
end
