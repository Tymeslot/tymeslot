defmodule Tymeslot.Infrastructure.RetryLogicTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.RetryLogic

  describe "with_retry/2" do
    test "returns success on first attempt" do
      assert {:ok, :done} = RetryLogic.with_retry(fn -> {:ok, :done} end)
    end

    test "retries on retryable error and succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        RetryLogic.with_retry(
          fn ->
            count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
            if count < 2, do: {:error, :network_error}, else: {:ok, :recovered}
          end,
          base_delay_ms: 1,
          max_delay_ms: 10,
          max_retries: 5
        )

      assert {:ok, :recovered} = result
    end

    test "returns last error after exhausting retries" do
      result =
        RetryLogic.with_retry(
          fn -> {:error, :timeout} end,
          max_retries: 2,
          base_delay_ms: 1,
          max_delay_ms: 10
        )

      assert {:error, :timeout} = result
    end

    test "does not retry non-retryable errors" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        RetryLogic.with_retry(
          fn ->
            Agent.update(counter, &(&1 + 1))
            {:error, :unauthorized}
          end,
          base_delay_ms: 1,
          max_delay_ms: 10
        )

      assert {:error, :unauthorized} = result
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "calculate_delay/4" do
    test "first attempt uses base delay" do
      delay = RetryLogic.calculate_delay(0, 1000, 30_000, 0.0)
      assert delay == 1000
    end

    test "delay doubles with each attempt" do
      delay_0 = RetryLogic.calculate_delay(0, 1000, 30_000, 0.0)
      delay_1 = RetryLogic.calculate_delay(1, 1000, 30_000, 0.0)
      delay_2 = RetryLogic.calculate_delay(2, 1000, 30_000, 0.0)

      assert delay_0 == 1000
      assert delay_1 == 2000
      assert delay_2 == 4000
    end

    test "caps at max delay" do
      delay = RetryLogic.calculate_delay(10, 1000, 5000, 0.0)
      assert delay == 5000
    end

    test "jitter stays within expected range" do
      # Run many times to check bounds
      delays =
        for _i <- 1..100 do
          RetryLogic.calculate_delay(0, 1000, 30_000, 0.1)
        end

      # With jitter_factor 0.1, delay should be in [900, 1100]
      assert Enum.all?(delays, &(&1 >= 900 and &1 <= 1100))
    end
  end

  describe "retryable_error?/2" do
    test "atoms in the retryable list are retryable" do
      assert RetryLogic.retryable_error?(:network_error, [:network_error, :timeout])
      assert RetryLogic.retryable_error?(:timeout, [:network_error, :timeout])
    end

    test "atoms not in the list are not retryable" do
      refute RetryLogic.retryable_error?(:unauthorized, [:network_error, :timeout])
    end

    test "error tuples are checked by reason" do
      assert RetryLogic.retryable_error?({:error, :timeout}, [:timeout])
      refute RetryLogic.retryable_error?({:error, :not_found}, [:timeout])
    end

    test "string error tuples are not retryable" do
      refute RetryLogic.retryable_error?({:error, "something"}, [:timeout])
    end
  end
end
