defmodule Tymeslot.Infrastructure.RetryTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Retry

  describe "with_backoff/2" do
    test "returns success on first attempt" do
      assert {:ok, :done} = Retry.with_backoff(fn -> {:ok, :done} end)
    end

    test "retries on retriable error and succeeds" do
      {result, counter} =
        backoff_with_counter(2, {:error, "timeout"}, {:ok, :recovered}, max_attempts: 5)

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
      counter = new_counter()

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
      {result, _counter} =
        backoff_with_counter(1, {:error, :custom_error}, {:ok, :done},
          retriable?: fn reason -> reason == :custom_error end
        )

      assert {:ok, :done} = result
    end
  end

  describe "default_retriable?/1" do
    test "string patterns: retries timeout errors" do
      # Test via with_backoff since default_retriable? is private
      assert_retried_once({:error, "Connection timeout occurred"})
    end

    test "string patterns: does not retry unknown errors" do
      assert_not_retried({:error, "invalid credentials"})
    end

    test "exception patterns: retries Mint.TransportError timeout" do
      assert_retried_once({:error, %Mint.TransportError{reason: :timeout}})
    end

    test "exception patterns: does not retry non-transient Mint errors" do
      assert_not_retried({:error, %Mint.TransportError{reason: :nxdomain}})
    end
  end

  defp backoff_with_counter(succeed_after, error_result, success_result, opts) do
    counter = new_counter()

    result =
      Retry.with_backoff(
        fn ->
          n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
          if n < succeed_after, do: error_result, else: success_result
        end,
        Keyword.merge([initial_delay: 1, max_delay: 10], opts)
      )

    {result, counter}
  end

  defp new_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counter
  end

  defp assert_retried_once(error_result) do
    counter = new_counter()

    Retry.with_backoff(
      fn ->
        n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
        if n < 1, do: error_result, else: {:ok, :done}
      end,
      initial_delay: 1,
      max_delay: 10
    )

    assert Agent.get(counter, & &1) == 2
  end

  defp assert_not_retried(error_result) do
    counter = new_counter()

    Retry.with_backoff(
      fn ->
        Agent.update(counter, &(&1 + 1))
        error_result
      end,
      initial_delay: 1,
      max_delay: 10
    )

    assert Agent.get(counter, & &1) == 1
  end
end
