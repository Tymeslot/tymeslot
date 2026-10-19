defmodule Tymeslot.Integrations.HealthCheck.ErrorAnalysisTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis

  describe "analyze/2 with success" do
    test "returns success result unchanged" do
      health_state = %{failures: 0, backoff_ms: :timer.minutes(5)}

      assert ErrorAnalysis.analyze({:ok, :some_result}, health_state) == {:ok, :some_result}
    end
  end

  describe "analyze/2 with error" do
    test "classifies and returns transient errors" do
      health_state = %{failures: 0, backoff_ms: :timer.minutes(5)}

      assert ErrorAnalysis.analyze({:error, :timeout}, health_state) ==
               {:error, :timeout, :transient}
    end

    test "classifies and returns hard errors" do
      health_state = %{failures: 0, backoff_ms: :timer.minutes(5)}

      assert ErrorAnalysis.analyze({:error, :unauthorized}, health_state) ==
               {:error, :unauthorized, :hard}
    end
  end

  describe "classify_error/1 - transient errors" do
    test "classifies rate limit errors as transient" do
      assert ErrorAnalysis.classify_error({:error, :rate_limited}) == :transient

      assert ErrorAnalysis.classify_error({:error, :rate_limited, "Too many requests"}) ==
               :transient
    end

    test "classifies a bare ConnectionProbe rate-limit refusal as transient (belt-and-braces)" do
      # `HealthCheck.orchestrate_health_check/2` short-circuits on this exact
      # shape before it ever reaches `ErrorAnalysis` — a probe that never ran
      # is not a probe that failed — so this clause only matters if some
      # future caller lets one through anyway.
      assert ErrorAnalysis.classify_error({:rate_limited, "You've reached the limit"}) ==
               :transient
    end

    test "classifies HTTP 429 as transient" do
      assert ErrorAnalysis.classify_error({:http_error, 429, "Too Many Requests"}) == :transient
    end

    test "classifies HTTP 408 (timeout) as transient" do
      assert ErrorAnalysis.classify_error({:http_error, 408, "Request Timeout"}) == :transient
    end

    test "classifies HTTP 425 as transient" do
      assert ErrorAnalysis.classify_error({:http_error, 425, "Too Early"}) == :transient
    end

    test "classifies HTTP 5xx errors as transient" do
      assert ErrorAnalysis.classify_error({:http_error, 500, "Internal Server Error"}) ==
               :transient

      assert ErrorAnalysis.classify_error({:http_error, 502, "Bad Gateway"}) == :transient
      assert ErrorAnalysis.classify_error({:http_error, 503, "Service Unavailable"}) == :transient
      assert ErrorAnalysis.classify_error({:http_error, 504, "Gateway Timeout"}) == :transient
    end

    test "classifies network errors as transient" do
      assert ErrorAnalysis.classify_error(:timeout) == :transient
      assert ErrorAnalysis.classify_error(:nxdomain) == :transient
      assert ErrorAnalysis.classify_error(:econnrefused) == :transient
      assert ErrorAnalysis.classify_error(:network_error) == :transient
    end

    test "classifies string messages with 'timeout' as transient" do
      assert ErrorAnalysis.classify_error("Connection timeout") == :transient
      assert ErrorAnalysis.classify_error("Request timeout") == :transient
      assert ErrorAnalysis.classify_error("TIMEOUT ERROR") == :transient
    end

    test "classifies string messages with 'rate limit' as transient" do
      assert ErrorAnalysis.classify_error("Rate limit exceeded") == :transient
      assert ErrorAnalysis.classify_error("You have been rate limited") == :transient
      assert ErrorAnalysis.classify_error("RATE LIMIT") == :transient
    end

    test "classifies string messages with 'too many' as transient" do
      assert ErrorAnalysis.classify_error("Too many requests") == :transient
      assert ErrorAnalysis.classify_error("TOO MANY CONNECTIONS") == :transient
    end

    test "classifies exception wrappers with transient messages as transient" do
      assert ErrorAnalysis.classify_error({:exception, "Connection timeout"}) == :transient
      assert ErrorAnalysis.classify_error({:exception, "Rate limit exceeded"}) == :transient
    end
  end

  describe "classify_error/1 - hard errors" do
    test "classifies authorization errors as hard" do
      assert ErrorAnalysis.classify_error(:unauthorized) == :hard
      assert ErrorAnalysis.classify_error(:invalid_credentials) == :hard
      assert ErrorAnalysis.classify_error(:token_expired) == :hard
    end

    test "classifies the canonical auth HTTP statuses (401, 403, 404) as hard" do
      assert ErrorAnalysis.classify_error({:http_error, 401, "Unauthorized"}) == :hard
      assert ErrorAnalysis.classify_error({:http_error, 403, "Forbidden"}) == :hard
      assert ErrorAnalysis.classify_error({:http_error, 404, "Not Found"}) == :hard
    end

    test "classifies known permanent OAuth markers in strings as hard" do
      assert ErrorAnalysis.classify_error("invalid_grant") == :hard
      assert ErrorAnalysis.classify_error("OAuth: invalid_client") == :hard
      assert ErrorAnalysis.classify_error("access_denied") == :hard
    end

    # The same calendar meets the same cap on every retry.
    test "classifies a read past the page cap as hard" do
      assert ErrorAnalysis.classify_error(:too_many_pages) == :hard

      assert ErrorAnalysis.classify_error({:too_many_pages, "Graph read exceeded 100 pages"}) ==
               :hard
    end

    # The badge (this classifier) and the reconnect email (the fast path in
    # `ResponseHandler`) read one rule, so they cannot disagree.
    test "agrees with the reauth fast path on every permanent credential error" do
      reasons = [
        :unauthorized,
        :invalid_credentials,
        :token_expired,
        "invalid_grant",
        "Token has been expired or revoked. (invalid_grant)",
        "OAuth: invalid_client",
        {:exception, "access_denied: user revoked"}
      ]

      assert Enum.all?(reasons, &BreakerOutcome.permanent_credential_error?/1)
      assert Enum.reject(reasons, &(ErrorAnalysis.classify_error(&1) == :hard)) == []
    end

    # Whole words, as the fast path matches them: a marker inside a longer
    # token is not one.
    test "does not read a marker embedded in a longer word as hard" do
      assert ErrorAnalysis.classify_error("invalid_grant_period_started") == :transient
      assert ErrorAnalysis.classify_error("xaccess_denied") == :transient
    end

    test "classifies exception wrappers with hard auth markers as hard" do
      assert ErrorAnalysis.classify_error({:exception, "invalid_grant"}) == :hard
      assert ErrorAnalysis.classify_error({:exception, "access_denied: user revoked"}) == :hard
    end
  end

  describe "classify_error/1 - conservative default" do
    test "classifies unknown 4xx as transient (not 401/403/404)" do
      assert ErrorAnalysis.classify_error({:http_error, 400, "Bad Request"}) == :transient
      assert ErrorAnalysis.classify_error({:http_error, 422, "Unprocessable"}) == :transient
      assert ErrorAnalysis.classify_error({:http_error, 423, "Locked"}) == :transient
    end

    test "classifies opaque server-returned strings as transient" do
      assert ErrorAnalysis.classify_error("Server is busy, try again") == :transient
      assert ErrorAnalysis.classify_error("Unexpected response") == :transient
      assert ErrorAnalysis.classify_error("Resource not found") == :transient
    end

    test "classifies unknown atoms as transient" do
      assert ErrorAnalysis.classify_error(:unknown_error) == :transient
      assert ErrorAnalysis.classify_error({:weird, :error}) == :transient
      assert ErrorAnalysis.classify_error(123) == :transient
    end

    test "classifies invalid UTF-8 strings as transient" do
      invalid_string = <<255>>
      assert ErrorAnalysis.classify_error(invalid_string) == :transient
    end
  end

  describe "calculate_next_backoff/2" do
    test "starts the ramp at the short interval on the first failure after a passing probe" do
      health_state = %{backoff_ms: :timer.minutes(30), last_error_class: nil}

      next_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :transient)

      assert next_backoff == :timer.minutes(5)
    end

    test "doubles backoff for subsequent transient errors" do
      health_state = %{backoff_ms: :timer.minutes(5)}

      next_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :transient)

      assert next_backoff == :timer.minutes(10)
    end

    test "uses fixed 1-hour interval for hard errors" do
      health_state = %{backoff_ms: :timer.minutes(30)}

      next_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :hard)

      assert next_backoff == :timer.hours(1)
    end

    test "uses fixed 1-hour interval for hard errors regardless of current backoff" do
      health_state = %{backoff_ms: :timer.minutes(5)}

      next_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :hard)

      assert next_backoff == :timer.hours(1)
    end

    test "respects maximum backoff cap for transient errors" do
      # Start near the cap
      health_state = %{backoff_ms: :timer.minutes(40)}

      next_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :transient)

      # Should cap at 1 hour
      assert next_backoff == :timer.hours(1)
    end

    # The first probe after an integration goes unhealthy comes 15 minutes
    # later. A transient failure from there used to double to exactly the
    # healthy interval, which the next one read as "coming from healthy" and
    # restarted at 5 minutes: 15, 30, 5, 10...
    test "a transient failure after the first unhealthy probe keeps climbing" do
      after_unhealthy = %{backoff_ms: :timer.minutes(15), last_error_class: :hard}
      first = ErrorAnalysis.calculate_next_backoff(after_unhealthy, :transient)

      second =
        ErrorAnalysis.calculate_next_backoff(
          %{backoff_ms: first, last_error_class: :transient},
          :transient
        )

      assert [first, second] == [:timer.minutes(30), :timer.hours(1)]
    end

    test "transient backoff sequence from initial 5min" do
      expected_sequence = [
        :timer.minutes(10),
        :timer.minutes(20),
        :timer.minutes(40),
        :timer.hours(1),
        :timer.hours(1)
      ]

      result =
        Enum.reduce(1..5, [], fn _iteration, acc ->
          current_ms = if acc == [], do: :timer.minutes(5), else: List.last(acc)

          next_backoff =
            ErrorAnalysis.calculate_next_backoff(%{backoff_ms: current_ms}, :transient)

          acc ++ [next_backoff]
        end)

      assert result == expected_sequence
    end
  end
end
