defmodule Tymeslot.Integrations.Calendar.RequestCoalescer do
  @moduledoc """
  Coalesces identical calendar API requests to prevent duplicate calls.

  When multiple requests for the same date range occur simultaneously,
  only one API call is made and the result is shared with all waiters.

  This is NOT a cache - each unique request will hit the API.
  It only deduplicates identical concurrent requests.
  """

  use GenServer
  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Base

  # Client API

  @doc """
  Starts the RequestCoalescer GenServer.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Coalesces identical requests for calendar events.

  If an identical request is already in-flight, waits for its result.
  Otherwise, executes the fetch function and shares the result.
  """
  @spec coalesce(integer(), Date.t(), Date.t(), function()) ::
          {:ok, list(map())} | {:error, term()}
  def coalesce(user_id, start_date, end_date, fetch_fn) when is_function(fetch_fn, 0) do
    key = {user_id, start_date, end_date}

    GenServer.call(__MODULE__, {:coalesce, key, fetch_fn}, Base.coalescer_call_timeout_ms())
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # State structure: %{requests: %{key => %{task_ref: ref, waiters: [from], start_time: timestamp}}}
    {:ok, %{requests: %{}}}
  end

  @impl true
  def handle_call({:coalesce, key, fetch_fn}, from, state) do
    case Map.get(state.requests, key) do
      nil ->
        # start_fetch returns %{pid: pid, ref: ref} - not a Task struct
        fetch_handle = start_fetch(key, fetch_fn)

        new_request = %{
          task_ref: fetch_handle.ref,
          task_pid: fetch_handle.pid,
          waiters: [from],
          start_time: System.monotonic_time(:millisecond)
        }

        new_state = put_in(state.requests[key], new_request)

        # Don't reply yet - we'll reply when the task completes
        {:noreply, new_state}

      %{waiters: waiters} = request ->
        # Request in-flight, add to waiters
        updated_request = %{request | waiters: [from | waiters]}
        new_state = put_in(state.requests[key], updated_request)

        Logger.debug("Coalescing request for #{inspect(key)}, #{length(waiters) + 1} waiters")

        # Don't reply yet - we'll reply when the task completes
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Consume unexpected task messages to avoid warnings
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task process died - find and clean up the request
    case find_key_by_ref(state.requests, ref) do
      nil ->
        {:noreply, state}

      key ->
        # If task exited normally, it already sent :coalescer_result before exiting.
        # Let that message handler reply to waiters. Only handle crashes here.
        if reason == :normal do
          # Normal exit - :coalescer_result message is in mailbox or already processed
          # Just flush the monitor, let :coalescer_result handle the reply
          Process.demonitor(ref, [:flush])
          {:noreply, state}
        else
          # Abnormal exit (crash) - reply with error to all waiters
          waiters = get_in(state, [:requests, key, :waiters]) || []
          Process.demonitor(ref, [:flush])

          Logger.warning("Fetch task crashed for #{inspect(key)}", reason: inspect(reason))

          Enum.each(waiters, fn waiter -> GenServer.reply(waiter, {:error, :task_died}) end)
          {:noreply, %{state | requests: Map.delete(state.requests, key)}}
        end
    end
  end

  @impl true
  def handle_info({:coalescer_result, key, _pid, result}, state) do
    case Map.pop(state.requests, key) do
      {nil, _} ->
        {:noreply, state}

      {%{waiters: waiters, task_ref: ref, start_time: start_time}, requests} ->
        Process.demonitor(ref, [:flush])

        Enum.each(waiters, fn waiter ->
          GenServer.reply(waiter, result)
        end)

        elapsed = System.monotonic_time(:millisecond) - start_time

        Logger.debug(
          "Request for #{inspect(key)} completed in #{elapsed}ms, served #{length(waiters)} clients"
        )

        {:noreply, %{state | requests: requests}}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("RequestCoalescer received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp find_key_by_ref(requests, ref) do
    Enum.find_value(requests, fn
      {k, %{task_ref: ^ref}} -> k
      _ -> nil
    end)
  end

  defp start_fetch(key, fetch_fn) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        result =
          try do
            fetch_fn.()
          rescue
            e ->
              {:error, {:task_failed, Exception.format(:error, e, __STACKTRACE__)}}
          catch
            :exit, {:timeout, _} -> {:error, :timeout}
            :exit, reason -> {:error, {:task_failed, reason}}
          end

        send(parent, {:coalescer_result, key, self(), result})
      end)

    ref = Process.monitor(pid)
    %{pid: pid, ref: ref}
  end
end
