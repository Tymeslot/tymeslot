defmodule Tymeslot.Integrations.Stripe.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Stripe.Request
  alias Tymeslot.Integrations.Stripe.RetryPolicy

  @moduletag :payments
  @moduletag :unit

  @retry_true [{"stripe-should-retry", "true"}]
  @retry_false [{"stripe-should-retry", "false"}]

  # {description, request fields, outcome, attempt, elapsed_ms, last_attempt_ms, expected}
  # Every row uses base_ms 250 and random 1.0 unless its request fields override them.
  @cases [
    {"a POST connect failure is retried", [method: :post], {:transport, :connect, :econnrefused},
     1, 0, 10, {:retry, 250}},
    {"a POST timeout after sending is retried on attempt 1", [method: :post],
     {:transport, :after_send, :timeout}, 1, 0, 10, {:retry, 250}},
    {"a POST timeout after sending doubles the delay on attempt 2", [method: :post],
     {:transport, :after_send, :timeout}, 2, 0, 10, {:retry, 500}},
    {"a third attempt is never followed by a fourth", [method: :post],
     {:transport, :after_send, :timeout}, 3, 0, 10, :stop},
    {"a GET timeout after sending is retried", [method: :get],
     {:transport, :after_send, :timeout}, 1, 0, 10, {:retry, 250}},
    {"a DELETE closed connection is retried", [method: :delete],
     {:transport, :after_send, :closed}, 1, 0, 10, {:retry, 250}},
    {"a POST 500 is not retried", [method: :post], {:response, 500, [], nil}, 1, 0, 10, :stop},
    {"a GET 500 is retried", [method: :get], {:response, 500, [], nil}, 1, 0, 10, {:retry, 250}},
    {"a DELETE 503 is retried", [method: :delete], {:response, 503, [], nil}, 1, 0, 10,
     {:retry, 250}},
    {"a POST 500 Stripe says to retry is retried", [method: :post],
     {:response, 500, @retry_true, nil}, 1, 0, 10, {:retry, 250}},
    {"a GET 500 Stripe says not to retry is not retried", [method: :get],
     {:response, 500, @retry_false, nil}, 1, 0, 10, :stop},
    {"a POST 429 lock timeout is retried", [method: :post], {:response, 429, [], "lock_timeout"},
     1, 0, 10, {:retry, 250}},
    {"a GET 429 rate limit is not retried", [method: :get], {:response, 429, [], "rate_limit"}, 1,
     0, 10, :stop},
    {"a 429 without a code is not retried", [method: :get], {:response, 429, [], nil}, 1, 0, 10,
     :stop},
    {"a 429 rate limit Stripe says to retry is retried", [method: :post],
     {:response, 429, @retry_true, "rate_limit"}, 1, 0, 10, {:retry, 250}},
    {"a 429 lock timeout Stripe says not to retry is not retried", [method: :post],
     {:response, 429, @retry_false, "lock_timeout"}, 1, 0, 10, :stop},
    {"a POST 409 is retried", [method: :post], {:response, 409, [], nil}, 1, 0, 10,
     {:retry, 250}},
    {"a POST 409 Stripe says not to retry is not retried", [method: :post],
     {:response, 409, @retry_false, nil}, 1, 0, 10, :stop},
    {"a POST 400 is not retried", [method: :post], {:response, 400, [], nil}, 1, 0, 10, :stop},
    {"a POST 402 is not retried", [method: :post], {:response, 402, [], nil}, 1, 0, 10, :stop},
    {"a POST 404 is not retried", [method: :post], {:response, 404, [], nil}, 1, 0, 10, :stop},
    {"a retry that would overrun the deadline stops", [method: :get, deadline_ms: 10_000],
     {:response, 500, [], nil}, 1, 9_000, 900, :stop},
    {"a retry that fits the deadline goes ahead", [method: :get, deadline_ms: 10_000],
     {:response, 500, [], nil}, 1, 8_000, 900, {:retry, 250}},
    {"an instant last attempt still counts one millisecond against the deadline",
     [method: :get, deadline_ms: 1_000], {:response, 500, [], nil}, 1, 750, 0, :stop},
    {"the lowest jitter halves the delay", [method: :get, random: 0.0], {:response, 500, [], nil},
     1, 0, 10, {:retry, 125}},
    {"a zero base gives a zero delay", [method: :get, base_ms: 0], {:response, 500, [], nil}, 1,
     0, 10, {:retry, 0}},
    {"attempt 2 doubles a 300 ms base", [method: :get, base_ms: 300], {:response, 500, [], nil},
     2, 0, 10, {:retry, 600}},
    {"attempt 2 doubles a 600 ms base, under the cap", [method: :get, base_ms: 600],
     {:response, 500, [], nil}, 2, 0, 10, {:retry, 1_200}}
  ]

  for {description, fields, outcome, attempt, elapsed_ms, last_attempt_ms, expected} <- @cases do
    test description do
      fields = unquote(fields)
      {request_fields, policy_fields} = Keyword.split(fields, [:method, :deadline_ms])

      request =
        Request.new(:test_operation, Keyword.fetch!(request_fields, :method), ["things"], %{},
          deadline_ms: Keyword.get(request_fields, :deadline_ms, 10_000),
          connect_timeout: 100
        )

      inputs = %{
        outcome: unquote(Macro.escape(outcome)),
        attempt: unquote(attempt),
        elapsed_ms: unquote(elapsed_ms),
        last_attempt_ms: unquote(last_attempt_ms),
        random: Keyword.get(policy_fields, :random, 1.0),
        base_ms: Keyword.get(policy_fields, :base_ms, 250)
      }

      assert RetryPolicy.decide(request, inputs) == unquote(Macro.escape(expected))
    end
  end

  describe "attempt_timeouts/2" do
    @request Request.new(:retrieve_charge, :get, ["charges", "ch_1"], %{},
               deadline_ms: 10_000,
               receive_timeout: 8_000
             )

    for {description, fields, elapsed_ms, expected} <- [
          {"a fresh call gets the configured receive timeout and Finch's pool timeout", [], 0,
           {:ok, %{receive_timeout: 8_000, pool_timeout: 5_000}}},
          {"a late attempt has both capped at the time left", [], 7_000,
           {:ok, %{receive_timeout: 3_000, pool_timeout: 3_000}}},
          {"one millisecond left is still an attempt", [], 9_999,
           {:ok, %{receive_timeout: 1, pool_timeout: 1}}},
          {"a short configured receive timeout is never raised", [receive_timeout: 1_000], 0,
           {:ok, %{receive_timeout: 1_000, pool_timeout: 5_000}}},
          {"no time left has expired", [], 10_000, :expired},
          {"a call past its deadline has expired", [], 12_000, :expired}
        ] do
      test description do
        request = struct!(@request, unquote(fields))

        assert RetryPolicy.attempt_timeouts(request, unquote(elapsed_ms)) ==
                 unquote(Macro.escape(expected))
      end
    end
  end

  describe "transport_phase/1" do
    for {reason, expected} <- [
          econnrefused: :connect,
          nxdomain: :connect,
          ehostunreach: :connect,
          timeout: :after_send,
          closed: :after_send,
          protocol_not_negotiated: :after_send
        ] do
      test "#{reason} is #{expected}" do
        assert RetryPolicy.transport_phase(unquote(reason)) == unquote(expected)
      end
    end

    test "a non-atom reason is after-send" do
      assert RetryPolicy.transport_phase({:raised, RuntimeError}) == :after_send
    end
  end
end
