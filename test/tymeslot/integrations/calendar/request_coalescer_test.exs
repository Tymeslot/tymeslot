defmodule Tymeslot.Integrations.Calendar.RequestCoalescerTest do
  use ExUnit.Case, async: false

  alias Tymeslot.Integrations.Calendar.RequestCoalescer

  @receive_timeout 2_000
  @await_timeout 5_000

  setup do
    Agent.start_link(fn -> 0 end, name: __MODULE__.Counter)

    on_exit(fn ->
      if Process.whereis(__MODULE__.Counter) do
        try do
          Agent.stop(__MODULE__.Counter)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp counter, do: Agent.get(__MODULE__.Counter, & &1)

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
      for _ <- 1..5 do
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

    for _ <- 1..5 do
      assert_receive {:caller_ready, ^ref, _pid}, @receive_timeout
    end

    Enum.each(tasks, fn task -> send(task.pid, {:go, ref}) end)

    assert_receive {:fetch_started, ^ref, fetch_pid}, @receive_timeout
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
      for _ <- 1..3 do
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

    for _ <- 1..3 do
      assert_receive {:caller_ready, ^ref, _pid}, @receive_timeout
    end

    Enum.each(tasks, fn task -> send(task.pid, {:go, ref}) end)

    assert_receive {:fetch_started, ^ref, fetch_pid}, @receive_timeout
    send(fetch_pid, {:release_fetch, ref})

    results = Task.await_many(tasks, @await_timeout)

    assert Enum.all?(results, &(&1 == {:error, :timeout}))
    assert counter() == 1
  end
end
