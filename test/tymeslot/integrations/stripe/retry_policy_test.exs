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
    {"a POST 500 is not retried", [method: :post], {:response, 500, []}, 1, 0, 10, :stop},
    {"a GET 500 is retried", [method: :get], {:response, 500, []}, 1, 0, 10, {:retry, 250}},
    {"a DELETE 503 is retried", [method: :delete], {:response, 503, []}, 1, 0, 10, {:retry, 250}},
    {"a POST 500 Stripe says to retry is retried", [method: :post], {:response, 500, @retry_true},
     1, 0, 10, {:retry, 250}},
    {"a GET 500 Stripe says not to retry is not retried", [method: :get],
     {:response, 500, @retry_false}, 1, 0, 10, :stop},
    {"a POST 429 is retried", [method: :post], {:response, 429, []}, 1, 0, 10, {:retry, 250}},
    {"a POST 409 is retried", [method: :post], {:response, 409, []}, 1, 0, 10, {:retry, 250}},
    {"a POST 409 Stripe says not to retry is not retried", [method: :post],
     {:response, 409, @retry_false}, 1, 0, 10, :stop},
    {"a POST 400 is not retried", [method: :post], {:response, 400, []}, 1, 0, 10, :stop},
    {"a POST 402 is not retried", [method: :post], {:response, 402, []}, 1, 0, 10, :stop},
    {"a POST 404 is not retried", [method: :post], {:response, 404, []}, 1, 0, 10, :stop},
    {"a retry that would overrun the deadline stops", [method: :get, deadline_ms: 10_000],
     {:response, 500, []}, 1, 9_000, 900, :stop},
    {"a retry that fits the deadline goes ahead", [method: :get, deadline_ms: 10_000],
     {:response, 500, []}, 1, 8_000, 900, {:retry, 250}},
    {"an instant last attempt still counts one millisecond against the deadline",
     [method: :get, deadline_ms: 1_000], {:response, 500, []}, 1, 750, 0, :stop},
    {"the lowest jitter halves the delay", [method: :get, random: 0.0], {:response, 500, []}, 1,
     0, 10, {:retry, 125}},
    {"a zero base gives a zero delay", [method: :get, base_ms: 0], {:response, 500, []}, 1, 0, 10,
     {:retry, 0}},
    {"attempt 2 doubles a 300 ms base", [method: :get, base_ms: 300], {:response, 500, []}, 2, 0,
     10, {:retry, 600}},
    {"attempt 2 doubles a 600 ms base, under the cap", [method: :get, base_ms: 600],
     {:response, 500, []}, 2, 0, 10, {:retry, 1_200}}
  ]

  for {description, fields, outcome, attempt, elapsed_ms, last_attempt_ms, expected} <- @cases do
    test description do
      fields = unquote(fields)
      {request_fields, policy_fields} = Keyword.split(fields, [:method, :deadline_ms])

      request =
        Request.new(:test_operation, Keyword.fetch!(request_fields, :method), ["things"], %{},
          deadline_ms: Keyword.get(request_fields, :deadline_ms, 10_000)
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
end
