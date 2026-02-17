defmodule Tymeslot.Payments.RetryHelperTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Payments.RetryHelper

  describe "execute_with_retry/2" do
    test "returns ok result on first attempt" do
      operation = fn -> {:ok, "success"} end

      assert {:ok, "success"} = RetryHelper.execute_with_retry(operation)
    end

    test "returns error result when not retryable" do
      operation = fn -> {:error, :not_retryable} end

      assert {:error, :not_retryable} = RetryHelper.execute_with_retry(operation)
    end

    test "retries on network errors" do
      # Simulate network error followed by success
      {:ok, agent_pid} = start_counter_agent()

      operation = fn ->
        count = increment_counter(agent_pid)

        if count < 2 do
          {:error, %{source: :network}}
        else
          {:ok, "success"}
        end
      end

      assert {:ok, "success"} = RetryHelper.execute_with_retry(operation)

      # Should have called 3 times (2 failures + 1 success)
      assert get_counter(agent_pid) == 3
      stop_counter_agent(agent_pid)
    end

    test "retries on 5xx errors" do
      {:ok, agent_pid} = start_counter_agent()

      operation = fn ->
        count = increment_counter(agent_pid)

        if count < 1 do
          {:error, %{extra: %{http_status: 503}}}
        else
          {:ok, "recovered"}
        end
      end

      assert {:ok, "recovered"} = RetryHelper.execute_with_retry(operation)
      stop_counter_agent(agent_pid)
    end

    test "does not retry on 4xx errors" do
      operation = fn -> {:error, %{extra: %{http_status: 404}}} end

      assert {:error, %{extra: %{http_status: 404}}} = RetryHelper.execute_with_retry(operation)
    end

    test "respects max_attempts option" do
      {:ok, agent_pid} = start_counter_agent()

      operation = fn ->
        increment_counter(agent_pid)
        {:error, %{source: :network}}
      end

      assert {:error, %{source: :network}} =
               RetryHelper.execute_with_retry(operation, max_attempts: 2)

      # Should have attempted exactly 2 times
      assert get_counter(agent_pid) == 2
      stop_counter_agent(agent_pid)
    end

    test "uses custom retryable error function" do
      custom_retryable = fn
        :custom_retry -> true
        _other -> false
      end

      {:ok, agent_pid} = start_counter_agent()

      operation = fn ->
        count = increment_counter(agent_pid)

        if count < 1 do
          {:error, :custom_retry}
        else
          {:ok, "success"}
        end
      end

      assert {:ok, "success"} =
               RetryHelper.execute_with_retry(operation, retryable_error?: custom_retryable)

      stop_counter_agent(agent_pid)
    end

    test "handles exceptions and retries" do
      {:ok, agent_pid} = start_counter_agent()

      operation = fn ->
        count = increment_counter(agent_pid)

        if count < 1 do
          raise RuntimeError, "transient error"
        else
          {:ok, "recovered"}
        end
      end

      assert {:ok, "recovered"} = RetryHelper.execute_with_retry(operation)
      stop_counter_agent(agent_pid)
    end

    test "returns error after max retries for exceptions" do
      operation = fn -> raise RuntimeError, "persistent error" end

      assert {:error, %RuntimeError{}} =
               RetryHelper.execute_with_retry(operation, max_attempts: 2)
    end

    test "respects base_delay_ms option" do
      agent = Agent.start_link(fn -> [] end)
      {:ok, agent_pid} = agent

      operation = fn ->
        # Record timestamp
        Agent.update(agent_pid, fn timestamps ->
          [System.monotonic_time(:millisecond) | timestamps]
        end)

        {:error, %{source: :network}}
      end

      RetryHelper.execute_with_retry(operation, max_attempts: 3, base_delay_ms: 50)

      timestamps = Enum.reverse(Agent.get(agent_pid, & &1))

      # Check delays between attempts (should be ~50ms and ~100ms for linear backoff)
      if length(timestamps) >= 2 do
        delay1 =
          Enum.at(timestamps, 1) -
            Enum.at(timestamps, 0)

        # Allow some margin for test execution time
        assert delay1 >= 45 and delay1 <= 100
      end

      Agent.stop(agent_pid)
    end
  end

  describe "default_retryable_error?/1" do
    test "returns true for network errors" do
      assert RetryHelper.default_retryable_error?(%{source: :network}) == true
    end

    test "returns true for 5xx errors" do
      assert RetryHelper.default_retryable_error?(%{extra: %{http_status: 500}}) == true
      assert RetryHelper.default_retryable_error?(%{extra: %{http_status: 503}}) == true
      assert RetryHelper.default_retryable_error?(%{extra: %{http_status: 599}}) == true
    end

    test "returns false for 4xx errors" do
      assert RetryHelper.default_retryable_error?(%{extra: %{http_status: 400}}) == false
      assert RetryHelper.default_retryable_error?(%{extra: %{http_status: 404}}) == false
      assert RetryHelper.default_retryable_error?(%{extra: %{http_status: 422}}) == false
    end

    test "returns true for RuntimeError" do
      assert RetryHelper.default_retryable_error?(%RuntimeError{}) == true
    end

    test "returns true for ErlangError" do
      assert RetryHelper.default_retryable_error?(%ErlangError{}) == true
    end

    test "returns false for other errors" do
      assert RetryHelper.default_retryable_error?(:invalid_params) == false
      assert RetryHelper.default_retryable_error?(%{error: "unknown"}) == false
    end
  end

  describe "configuration" do
    test "uses default config when not specified" do
      # Default: max_attempts: 3, base_delay_ms: 1000
      {:ok, agent_pid} = start_counter_agent()

      operation = fn ->
        increment_counter(agent_pid)
        {:error, %{source: :network}}
      end

      RetryHelper.execute_with_retry(operation)

      # Should attempt 3 times by default
      assert get_counter(agent_pid) == 3
      stop_counter_agent(agent_pid)
    end
  end

  # Helper functions

  defp start_counter_agent do
    Agent.start_link(fn -> 0 end)
  end

  defp increment_counter(agent_pid) do
    Agent.get_and_update(agent_pid, fn count -> {count, count + 1} end)
  end

  defp get_counter(agent_pid) do
    Agent.get(agent_pid, fn count -> count end)
  end

  defp stop_counter_agent(agent_pid) do
    Agent.stop(agent_pid)
  end
end
