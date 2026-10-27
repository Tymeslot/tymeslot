defmodule Tymeslot.Integrations.Calendar.RequestCoalescerTest do
  use ExUnit.Case, async: false
  @moduletag :integrations

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Integrations.Calendar.Runtime.RequestCoalescer
  alias Tymeslot.Test.LogCapture

  @receive_timeout 2_000
  @await_timeout 5_000

  setup do
    Agent.start_link(fn -> 0 end, name: __MODULE__.Counter)

    on_exit(fn ->
      if Process.whereis(__MODULE__.Counter) do
        try do
          Agent.stop(__MODULE__.Counter)
        catch
          :exit, _exit_signal -> :ok
        end
      end
    end)

    :ok
  end

  defp counter, do: Agent.get(__MODULE__.Counter, & &1)

  defp wait_for_waiters(expected_count, attempts \\ 50) do
    %{requests: requests} = :sys.get_state(RequestCoalescer)
    total_waiters = requests |> Map.values() |> Enum.map(&length(&1.waiters)) |> Enum.sum()

    if total_waiters >= expected_count do
      :ok
    else
      if attempts <= 0, do: raise("Timed out waiting for #{expected_count} waiters")
      Process.sleep(10)
      wait_for_waiters(expected_count, attempts - 1)
    end
  end

  test "coalesces identical concurrent requests and shares the result" do
    parent = self()
    ref = make_ref()

    user_id = System.unique_integer([:positive])
    start_date = ~D[2024-01-01]
    end_date = ~D[2024-01-07]

    fetch_fn = fn ->
      Agent.update(__MODULE__.Counter, &(&1 + 1))
      send(parent, {:fetch_started, ref, self()})

      receive do
        {:release_fetch, ^ref} -> {:ok, [:event]}
      after
        @receive_timeout -> {:error, :test_timeout}
      end
    end

    tasks =
      for _task_num <- 1..5 do
        Task.async(fn ->
          send(parent, {:caller_ready, ref, self()})

          receive do
            {:go, ^ref} -> :ok
          end

          RequestCoalescer.coalesce(user_id, start_date, end_date, fn ->
            fetch_fn.()
          end)
        end)
      end

    for _i <- 1..5 do
      assert_receive {:caller_ready, ^ref, _pid}, @receive_timeout
    end

    Enum.each(tasks, fn task -> send(task.pid, {:go, ref}) end)

    assert_receive {:fetch_started, ^ref, fetch_pid}, @receive_timeout
    wait_for_waiters(5)
    send(fetch_pid, {:release_fetch, ref})

    results = Task.await_many(tasks, @await_timeout)

    assert Enum.all?(results, &(&1 == {:ok, [:event]}))
    assert counter() == 1
  end

  test "returns the same error to all waiters when the fetch fails" do
    parent = self()
    ref = make_ref()

    user_id = System.unique_integer([:positive])
    start_date = ~D[2024-02-01]
    end_date = ~D[2024-02-10]

    fetch_fn = fn ->
      Agent.update(__MODULE__.Counter, &(&1 + 1))
      send(parent, {:fetch_started, ref, self()})

      receive do
        {:release_fetch, ^ref} -> {:error, :timeout}
      after
        @receive_timeout -> {:error, :test_timeout}
      end
    end

    tasks =
      for _task_num <- 1..3 do
        Task.async(fn ->
          send(parent, {:caller_ready, ref, self()})

          receive do
            {:go, ^ref} -> :ok
          end

          RequestCoalescer.coalesce(user_id, start_date, end_date, fn ->
            fetch_fn.()
          end)
        end)
      end

    for _i <- 1..3 do
      assert_receive {:caller_ready, ^ref, _pid}, @receive_timeout
    end

    Enum.each(tasks, fn task -> send(task.pid, {:go, ref}) end)

    assert_receive {:fetch_started, ^ref, fetch_pid}, @receive_timeout
    wait_for_waiters(3)
    send(fetch_pid, {:release_fetch, ref})

    results = Task.await_many(tasks, @await_timeout)

    assert Enum.all?(results, &(&1 == {:error, :timeout}))
    assert counter() == 1
  end

  test "different keys run independently and each compute separately" do
    n = 3

    tasks =
      for i <- 1..n do
        user_id = System.unique_integer([:positive])

        Task.async(fn ->
          RequestCoalescer.coalesce(user_id, ~D[2024-03-01], ~D[2024-03-07], fn ->
            Agent.update(__MODULE__.Counter, &(&1 + 1))
            {:ok, {:result, i}}
          end)
        end)
      end

    results = Task.await_many(tasks, @await_timeout)

    # Each key should have triggered its own fetch
    assert counter() == n
    assert Enum.all?(results, &match?({:ok, {:result, _}}, &1))
  end

  test "runs the fetch with the caller's correlation id and error context" do
    ErrorTracking.put_context(correlation_id: "abc12345", user_id: 7)
    user_id = System.unique_integer([:positive])

    fetch_fn = fn ->
      {:ok,
       [
         %{
           correlation_id: Logger.metadata()[:correlation_id],
           tracker: ErrorTracker.get_context()["correlation_id"]
         }
       ]}
    end

    assert {:ok, [seen]} =
             RequestCoalescer.coalesce(user_id, ~D[2024-02-01], ~D[2024-02-07], fetch_fn)

    assert seen == %{correlation_id: "abc12345", tracker: "abc12345"}
  end

  describe "a fetch that fails" do
    # Stands in for a credential the fetch had in scope.
    @secret "password=hunter2"

    defp refute_leaks(reason) do
      rendered = inspect(reason, limit: :infinity, printable_limit: :infinity)

      refute rendered =~ "hunter2"
      refute rendered =~ ".ex:"
      refute rendered =~ "stacktrace"
    end

    test "tells a waiter on a raising call the exception's kind and nothing else" do
      assert {:error, {:task_failed, RuntimeError} = reason} =
               RequestCoalescer.coalesce(9_101, ~D[2024-04-01], ~D[2024-04-07], fn ->
                 raise @secret
               end)

      refute_leaks(reason)
    end

    test "tells a waiter on an exiting call the exit's kind and nothing else" do
      assert {:error, {:task_failed, :shutdown} = reason} =
               RequestCoalescer.coalesce(9_102, ~D[2024-04-01], ~D[2024-04-07], fn ->
                 exit({:shutdown, @secret})
               end)

      refute_leaks(reason)
    end

    test "keeps a raised exception's message in the server log" do
      LogCapture.attach()

      {:error, {:task_failed, RuntimeError}} =
        RequestCoalescer.coalesce(9_104, ~D[2024-04-01], ~D[2024-04-07], fn ->
          raise "the server closed the connection"
        end)

      event = LogCapture.await_log("Calendar fetch raised")
      assert event.meta.exception == "RuntimeError"
      assert event.meta.reason =~ "the server closed the connection"
    end

    test "keeps an exit's reason in the server log" do
      LogCapture.attach()

      {:error, {:task_failed, :shutdown}} =
        RequestCoalescer.coalesce(9_105, ~D[2024-04-01], ~D[2024-04-07], fn ->
          exit({:shutdown, :server_gone})
        end)

      event = LogCapture.await_log("Calendar fetch exited")
      assert event.meta.kind == ":shutdown"
      assert event.meta.reason =~ "server_gone"
    end

    test "tells a waiter on a call that exited with an exception only its kind" do
      assert {:error, {:task_failed, ArgumentError} = reason} =
               RequestCoalescer.coalesce(9_103, ~D[2024-04-01], ~D[2024-04-07], fn ->
                 exit({%ArgumentError{message: @secret}, [{__MODULE__, :fetch, 0, []}]})
               end)

      refute_leaks(reason)
    end
  end
end
