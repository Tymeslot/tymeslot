defmodule Tymeslot.Integrations.HealthCheck.ErrorAnalysisTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

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

    test "classifies HTTP 4xx (except 408, 425, 429) as hard" do
      assert ErrorAnalysis.classify_error({:http_error, 400, "Bad Request"}) == :hard
      assert ErrorAnalysis.classify_error({:http_error, 401, "Unauthorized"}) == :hard
      assert ErrorAnalysis.classify_error({:http_error, 403, "Forbidden"}) == :hard
      assert ErrorAnalysis.classify_error({:http_error, 404, "Not Found"}) == :hard
    end

    test "classifies generic string errors as hard" do
      assert ErrorAnalysis.classify_error("Invalid token") == :hard
      assert ErrorAnalysis.classify_error("Permission denied") == :hard
      assert ErrorAnalysis.classify_error("Resource not found") == :hard
    end

    test "classifies exception wrappers with hard error messages as hard" do
      assert ErrorAnalysis.classify_error({:exception, "Invalid credentials"}) == :hard
      assert ErrorAnalysis.classify_error({:exception, "Permission denied"}) == :hard
    end

    test "classifies unknown errors as hard" do
      assert ErrorAnalysis.classify_error(:unknown_error) == :hard
      assert ErrorAnalysis.classify_error({:weird, :error}) == :hard
      assert ErrorAnalysis.classify_error(123) == :hard
    end

    test "classifies invalid UTF-8 strings as hard" do
      invalid_string = <<255>>
      assert ErrorAnalysis.classify_error(invalid_string) == :hard
    end
  end

  describe "calculate_next_backoff/2" do
    test "doubles backoff for transient errors" do
      health_state = %{backoff_ms: :timer.minutes(30)}

      next_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :transient)

      assert next_backoff == :timer.hours(1)
    end

    test "keeps backoff unchanged for hard errors" do
      health_state = %{backoff_ms: :timer.minutes(30)}

      next_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :hard)

      assert next_backoff == :timer.minutes(30)
    end

    test "respects maximum backoff cap for transient errors" do
      # Start near the cap
      health_state = %{backoff_ms: :timer.minutes(45)}

      next_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :transient)

      # Should cap at 1 hour
      assert next_backoff == :timer.hours(1)
    end
  end
end
