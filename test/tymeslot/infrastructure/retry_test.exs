defmodule Tymeslot.Infrastructure.RetryTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.Retry

  # No waiting between attempts.
  @fast [initial_delay: 0, jitter: 0.0]

  defp quietly(fun), do: fun |> with_log() |> elem(0)

  defp counting(results) do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      Enum.at(results, :counters.get(counter, 1) - 1, List.last(results))
    end

    {fun, fn -> :counters.get(counter, 1) end}
  end

  describe "with_backoff/2" do
    test "returns a success from the first attempt" do
      {fun, calls} = counting([{:ok, :done}])

      assert {:ok, :done} = Retry.with_backoff(fun, @fast)
      assert calls.() == 1
    end

    test "retries a transient error until the call succeeds" do
      {fun, calls} = counting([{:error, :timeout}, {:error, :econnreset}, {:ok, :done}])

      assert {:ok, :done} = quietly(fn -> Retry.with_backoff(fun, @fast) end)
      assert calls.() == 3
    end

    # Callers report what went wrong; a bare "attempts exceeded" told them
    # nothing about why.
    test "returns the last error, not a placeholder, once the attempts run out" do
      {fun, calls} = counting([{:error, :timeout}, {:error, {:http_error, 503, "busy"}}])

      assert {:error, {:http_error, 503, "busy"}} =
               quietly(fn -> Retry.with_backoff(fun, @fast ++ [max_attempts: 2]) end)

      assert calls.() == 2
    end

    test "does not retry an error the breaker would not count as an outage" do
      for reason <- [:unauthorized, {:http_error, 404, ""}, "Something broke", :circuit_open] do
        {fun, calls} = counting([{:error, reason}, {:ok, :never}])

        assert {:error, ^reason} = Retry.with_backoff(fun, @fast)
        assert calls.() == 1, inspect(reason)
      end
    end

    test "retries the transport failures and statuses the breaker counts" do
      transient = [
        :econnreset,
        :econnrefused,
        :nxdomain,
        {:http_error, 429, ""},
        {:http_error, 502, ""},
        %Mint.TransportError{reason: :closed},
        %Req.TransportError{reason: :timeout},
        {:rate_limited, 30}
      ]

      for reason <- transient do
        {fun, calls} = counting([{:error, reason}, {:ok, :done}])

        assert {:ok, :done} = quietly(fn -> Retry.with_backoff(fun, @fast) end)
        assert calls.() == 2, inspect(reason)
      end
    end

    test "uses a caller's own retry rule" do
      {fun, calls} = counting([{:error, :custom}, {:ok, :done}])

      assert {:ok, :done} =
               quietly(fn ->
                 Retry.with_backoff(fun, @fast ++ [retriable?: &(&1 == :custom)])
               end)

      assert calls.() == 2
    end

    test "returns anything else as it is, without retrying" do
      for result <- [:ok, :error, {:error, :a, :b}, nil] do
        {fun, calls} = counting([result])

        assert Retry.with_backoff(fun, @fast) == result
        assert calls.() == 1
      end
    end
  end

  describe "a rate limit that names its wait" do
    test "is retried after that wait rather than the usual backoff" do
      {fun, calls} = counting([{:error, {:rate_limited, 1}}, {:ok, :done}])

      # The usual backoff here is no wait at all; the named second, capped.
      {elapsed_us, result} =
        :timer.tc(fn -> quietly(fn -> Retry.with_backoff(fun, @fast ++ [max_delay: 60]) end) end)

      assert result == {:ok, :done}
      assert calls.() == 2
      assert div(elapsed_us, 1_000) >= 60
    end

    test "waits no longer than the cap however long the wait named" do
      {fun, _calls} = counting([{:error, {:rate_limited, 3_600}}, {:ok, :done}])

      {elapsed_us, {:ok, :done}} =
        :timer.tc(fn -> quietly(fn -> Retry.with_backoff(fun, @fast ++ [max_delay: 10]) end) end)

      assert div(elapsed_us, 1_000) < 1_000
    end

    test "is returned at once when it asks for longer than the caller will wait" do
      {fun, calls} = counting([{:error, {:rate_limited, 3}}, {:ok, :done}])

      assert Retry.with_backoff(fun, @fast ++ [max_rate_limit_wait: 2_000]) ==
               {:error, {:rate_limited, 3}}

      assert calls.() == 1
    end

    test "is still retried when it asks for no more than the caller will wait" do
      {fun, calls} = counting([{:error, {:rate_limited, 2}}, {:ok, :done}])

      assert quietly(fn ->
               Retry.with_backoff(fun, @fast ++ [max_delay: 0, max_rate_limit_wait: 2_000])
             end) == {:ok, :done}

      assert calls.() == 2
    end
  end

  describe "retry_after_seconds/1" do
    test "reads a number of seconds, and nothing from a date or no header" do
      assert Retry.retry_after_seconds(%{headers: %{"retry-after" => ["30"]}}) == 30

      assert Retry.retry_after_seconds(%{
               headers: %{"retry-after" => ["Wed, 21 Oct 2026 07:28:00 GMT"]}
             }) == nil

      assert Retry.retry_after_seconds(%{headers: %{}}) == nil
    end
  end

  describe "delay/2" do
    test "starts at the initial delay and doubles up to the cap" do
      opts = [initial_delay: 1_000, max_delay: 3_000, jitter: 0.0]

      assert Enum.map(1..4, &Retry.delay(&1, opts)) == [1_000, 2_000, 3_000, 3_000]
    end

    test "jitter varies a delay by at most its fraction either way" do
      delays = for _n <- 1..200, do: Retry.delay(1, initial_delay: 1_000, jitter: 0.1)

      assert Enum.all?(delays, &(&1 in 900..1_100))
      assert length(Enum.uniq(delays)) > 1
    end
  end
end
