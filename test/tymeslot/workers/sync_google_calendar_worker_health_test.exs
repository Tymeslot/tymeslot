defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerHealthTest do
  @moduledoc """
  A Google calendar whose syncs keep failing must eventually turn its badge red.

  The worker used to feed health state exactly one signal: success, recorded
  while the sync token was being persisted. No failure branch recorded
  anything, so an account whose calls Google refused for days kept a green
  badge, was never sent the unhealthy notification and was never auto-paused —
  and because the success was recorded before the secondary calendars had been
  read at all, an integration whose second calendar failed every single cycle
  could not build a streak either. These tests drive the real worker against a
  refusing API and assert the streak reaches the badge.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :sync_failure_unhealthy_threshold, 3)

    integration =
      insert(:calendar_integration,
        provider: "google",
        google_sync_token: "valid-token",
        default_booking_calendar_id: "primary",
        is_active: true,
        needs_reauth: false
      )

    %{integration: integration}
  end

  defp health(integration), do: Monitor.get_state(:calendar, integration.id, integration.user_id)

  defp run_job(integration) do
    perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})
  end

  # A quota refusal is the plainest member of the catch-all family: no clause
  # names it, so before this behaviour existed it reached Oban as a retryable
  # error and told health state nothing at all.
  defp run_failing_sync(integration) do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:error, :rate_limited, "Quota exceeded"}
    end)

    assert {:error, _reason} = run_job(integration)
  end

  defp expect_successful_fetch do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: [], next_sync_token: "fresh-token"}}
    end)
  end

  describe "perform/1 against an API that refuses every call" do
    test "counts every failed cycle, and raises the badge on the third",
         %{integration: integration} do
      assert health(integration).consecutive_sync_failures == 0

      # Below the threshold the badge stays clear: a couple of failed cycles is
      # the transient blip Oban's own retries exist to absorb.
      for expected <- 1..2 do
        run_failing_sync(integration)

        assert %{consecutive_sync_failures: ^expected, status: :healthy, became_unhealthy_at: nil} =
                 health(integration)
      end

      run_failing_sync(integration)

      assert %{consecutive_sync_failures: 3, status: :unhealthy, became_unhealthy_at: %DateTime{}} =
               health(integration)
    end

    test "leaves consecutive_hard_failures alone so SyncGating does not pause the integration",
         %{integration: integration} do
      for _cycle <- 1..3, do: run_failing_sync(integration)

      state = health(integration)
      assert state.status == :unhealthy

      # Pausing sync is what would stop the integration ever discovering that
      # the quota had been restored.
      assert state.consecutive_hard_failures == 0
      assert state.failures == 0
    end

    test "a cycle that completes clears the streak again", %{integration: integration} do
      run_failing_sync(integration)
      assert health(integration).consecutive_sync_failures == 1

      expect_successful_fetch()
      assert :ok = run_job(integration)

      assert health(integration).consecutive_sync_failures == 0
    end

    test "a cycle that completes does not lower a badge the streak already raised",
         %{integration: integration} do
      for _cycle <- 1..3, do: run_failing_sync(integration)

      raised = health(integration)
      assert raised.status == :unhealthy

      expect_successful_fetch()
      assert :ok = run_job(integration)

      # One answered sync says the streak has ended, not that the outage has.
      # Clearing the episode here would restart the 48-hour notification clock
      # every time the API answered once, and the owner would never be told.
      state = health(integration)
      assert state.consecutive_sync_failures == 0
      assert state.status == :unhealthy
      assert state.became_unhealthy_at == raised.became_unhealthy_at
    end
  end

  describe "perform/1 on an integration with a secondary calendar" do
    setup do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "work@example.com", "selected" => true, "name" => "Work"}
          ]
        )

      %{multi: integration}
    end

    test "a cycle whose secondary calendar fails does not clear the streak", %{multi: multi} do
      # The success signal used to be recorded while the sync token was
      # persisted, which happens before the secondary calendars are read at
      # all. The primary's success therefore wiped the streak the secondary's
      # failure was building, the counter oscillated between 0 and 1 for as
      # long as the outage lasted, and the badge could never reach the
      # threshold that raises it.
      for expected <- 1..3 do
        expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
          {:ok, %{events: [], next_sync_token: "fresh-token"}}
        end)

        expect(GoogleCalendarAPIMock, :list_events, fn _integration, "work@example.com", _s, _e ->
          {:error, :api_error, "Backend error"}
        end)

        assert {:error, _reason} =
                 perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => multi.id})

        assert health(multi).consecutive_sync_failures == expected
      end

      assert health(multi).status == :unhealthy
    end
  end

  describe "perform/1 when the credentials are rejected" do
    test "counts the discarded cycle, which nothing else would report",
         %{integration: integration} do
      # A discard emits `job:stop`, which `ObanFailureAlerter` ignores by
      # design. The streak is the only thing that makes that quietness
      # temporary.
      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :unauthorized, "Token revoked"}
      end)

      assert {:discard, _reason} = run_job(integration)

      assert health(integration).consecutive_sync_failures == 1
    end
  end

  describe "perform/1 when the circuit breaker is open" do
    test "a snooze is not counted against this integration", %{integration: integration} do
      # The breaker is keyed by provider, not by integration: one account's
      # outage opens it for every Google account. Counting the refusal would
      # spread that account's failures across everyone else's badges.
      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :circuit_open}
      end)

      assert {:snooze, _seconds} = run_job(integration)

      assert health(integration).consecutive_sync_failures == 0
    end
  end

  describe "perform/1 during a bootstrap" do
    test "counts a failed bootstrap against the integration's health",
         %{integration: integration} do
      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :no_sync_token}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :rate_limited, "Quota exceeded"}
      end)

      assert {:error, _reason} = run_job(integration)

      assert health(integration).consecutive_sync_failures == 1
    end
  end
end
