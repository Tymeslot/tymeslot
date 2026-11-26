defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypesOperationalTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes
  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber

  # The notifier formats the scrubbed metadata, so the tests do too: a key the
  # scrubber redacts would otherwise pass here and read "[REDACTED]" in the
  # real alert.
  defp message(type, metadata), do: AlertTypes.format_message(type, PIIScrubber.scrub(metadata))

  describe ":circuit_breaker_open" do
    defp breaker(name, opened_at),
      do: %{breaker: name, opened_at: opened_at, failure_count: 5, old_state: :closed}

    test "is a warning" do
      assert %{severity: :warning} = AlertTypes.get(:circuit_breaker_open)
    end

    test "deduplicates per breaker within one hour" do
      first = breaker("google", "2026-09-27T14:01:00Z")
      again = %{breaker("google", "2026-09-27T14:59:00Z") | failure_count: 9}

      assert AlertTypes.dedup_key(:circuit_breaker_open, first) ==
               AlertTypes.dedup_key(:circuit_breaker_open, again)
    end

    test "alerts again in the next hour, and for another breaker" do
      first = breaker("google", "2026-09-27T14:01:00Z")

      refute AlertTypes.dedup_key(:circuit_breaker_open, first) ==
               AlertTypes.dedup_key(
                 :circuit_breaker_open,
                 breaker("google", "2026-09-27T15:01:00Z")
               )

      refute AlertTypes.dedup_key(:circuit_breaker_open, first) ==
               AlertTypes.dedup_key(
                 :circuit_breaker_open,
                 breaker("zoom", "2026-09-27T14:01:00Z")
               )
    end

    test "names the breaker, the failure count and the last error" do
      text =
        message(:circuit_breaker_open, %{
          breaker: "google",
          old_state: :closed,
          failure_count: 5,
          last_error: "timeout"
        })

      assert text == "Circuit breaker google opened after 5 failures (last error: timeout)"
    end

    test "says when a recovery probe reopened the breaker" do
      text =
        message(:circuit_breaker_open, %{
          breaker: "google",
          old_state: :half_open,
          failure_count: 5,
          last_error: "HTTP 503"
        })

      assert text ==
               "Circuit breaker google reopened: its recovery probe failed (last error: HTTP 503)"
    end
  end

  describe ":stripe_webhook_secret_missing" do
    test "is an error, deduplicated per secret" do
      assert %{severity: :error} = AlertTypes.get(:stripe_webhook_secret_missing)

      platform = %{env_var: "STRIPE_WEBHOOK_SECRET", summary: "a"}
      connect = %{env_var: "STRIPE_CONNECT_WEBHOOK_SECRET", summary: "a"}

      refute AlertTypes.dedup_key(:stripe_webhook_secret_missing, platform) ==
               AlertTypes.dedup_key(:stripe_webhook_secret_missing, connect)
    end

    test "names the missing variable" do
      text =
        message(:stripe_webhook_secret_missing, %{
          env_var: "STRIPE_CONNECT_WEBHOOK_SECRET",
          summary: "Booking payment webhooks are rejected"
        })

      assert text =~ "STRIPE_CONNECT_WEBHOOK_SECRET is not set"
      assert text =~ "Booking payment webhooks are rejected"
    end
  end

  describe ":database_pool_pressure" do
    defp pressure(repo, detected_at, count),
      do: %{
        repo: repo,
        detected_at: detected_at,
        slow_checkouts: count,
        threshold_ms: 500,
        window_seconds: 60
      }

    test "is a warning, deduplicated per repo within one hour" do
      assert %{severity: :warning} = AlertTypes.get(:database_pool_pressure)

      assert AlertTypes.dedup_key(
               :database_pool_pressure,
               pressure("Tymeslot.Repo", "2026-09-27T14:01:00Z", 25)
             ) ==
               AlertTypes.dedup_key(
                 :database_pool_pressure,
                 pressure("Tymeslot.Repo", "2026-09-27T14:30:00Z", 80)
               )

      refute AlertTypes.dedup_key(
               :database_pool_pressure,
               pressure("Tymeslot.Repo", "2026-09-27T14:01:00Z", 25)
             ) ==
               AlertTypes.dedup_key(
                 :database_pool_pressure,
                 pressure("Tymeslot.SaasRepo", "2026-09-27T14:01:00Z", 25)
               )
    end

    test "states how many queries waited too long, and over what window" do
      text =
        message(:database_pool_pressure, pressure("Tymeslot.Repo", "2026-09-27T14:01:00Z", 25))

      assert text ==
               "Database pool pressure on Tymeslot.Repo: 25 queries waited more than 500 ms " <>
                 "for a connection in the last 60 seconds"
    end
  end
end
