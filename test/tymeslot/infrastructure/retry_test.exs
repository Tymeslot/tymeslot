defmodule Tymeslot.Infrastructure.RetryTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Retry

  describe "with_backoff/2" do
    test "returns success on first attempt" do
      assert {:ok, :done} = Retry.with_backoff(fn -> {:ok, :done} end)
    end

    test "retries on retriable error and succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Retry.with_backoff(
          fn ->
            count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

            if count < 2 do
              {:error, "timeout"}
            else
              {:ok, :recovered}
            end
          end,
          initial_delay: 1,
          max_delay: 10,
          max_attempts: 5
        )

      assert {:ok, :recovered} = result
      assert Agent.get(counter, & &1) == 3
    end

    test "returns max_attempts_exceeded after exhausting retries" do
      result =
        Retry.with_backoff(
          fn -> {:error, "timeout"} end,
          max_attempts: 2,
          initial_delay: 1,
          max_delay: 10
        )

      assert {:error, :max_attempts_exceeded} = result
    end

    test "does not retry non-retriable errors" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Retry.with_backoff(
          fn ->
            Agent.update(counter, &(&1 + 1))
            {:error, :not_found}
          end,
          initial_delay: 1,
          max_delay: 10
        )

      assert {:error, :not_found} = result
      # Only called once — no retries for non-retriable errors
      assert Agent.get(counter, & &1) == 1
    end

    test "returns non-standard results without retry" do
      assert :something = Retry.with_backoff(fn -> :something end)
    end

    test "handles bare :error atom" do
      result =
        Retry.with_backoff(
          fn -> :error end,
          max_attempts: 2,
          initial_delay: 1,
          max_delay: 10
        )

      assert {:error, :max_attempts_exceeded} = result
    end

    test "respects custom retriable? function" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Retry.with_backoff(
          fn ->
            count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
            if count < 1, do: {:error, :custom_error}, else: {:ok, :done}
          end,
          initial_delay: 1,
          max_delay: 10,
          retriable?: fn reason -> reason == :custom_error end
        )

      assert {:ok, :done} = result
    end
  end

  describe "default_retriable?/1" do
    test "string patterns: retries timeout errors" do
      # Test via with_backoff since default_retriable? is private
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Retry.with_backoff(
        fn ->
          count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
          if count < 1, do: {:error, "Connection timeout occurred"}, else: {:ok, :done}
        end,
        initial_delay: 1,
        max_delay: 10
      )

      # Called twice (initial + 1 retry) proves timeout is retriable
      assert Agent.get(counter, & &1) == 2
    end

    test "string patterns: does not retry unknown errors" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Retry.with_backoff(
        fn ->
          Agent.update(counter, &(&1 + 1))
          {:error, "invalid credentials"}
        end,
        initial_delay: 1,
        max_delay: 10
      )

      assert Agent.get(counter, & &1) == 1
    end

    test "exception patterns: retries Mint.TransportError timeout" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Retry.with_backoff(
        fn ->
          count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

          if count < 1 do
            {:error, %Mint.TransportError{reason: :timeout}}
          else
            {:ok, :done}
          end
        end,
        initial_delay: 1,
        max_delay: 10
      )

      assert Agent.get(counter, & &1) == 2
    end

    test "exception patterns: does not retry non-transient Mint errors" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Retry.with_backoff(
        fn ->
          Agent.update(counter, &(&1 + 1))
          {:error, %Mint.TransportError{reason: :nxdomain}}
        end,
        initial_delay: 1,
        max_delay: 10
      )

      assert Agent.get(counter, & &1) == 1
    end
  end
end
