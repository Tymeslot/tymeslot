defmodule Tymeslot.Integrations.Calendar.TokenRefreshJobSnoozeBoundTest do
  @moduledoc """
  A snooze costs no attempt, so a refresh that keeps waiting for another
  refresh's lock, or for a rate limit that never lifts, must stop waiting by
  its own count of executions rather than by `max_attempts`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations
  @moduletag :calendar

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Shared.Lock

  setup :verify_on_exit!

  setup do
    integration =
      insert(:calendar_integration,
        provider: "google",
        token_expires_at: DateTime.add(DateTime.utc_now(:second), -1, :hour),
        refresh_token: "rt-123"
      )

    %{args: %{"integration_id" => integration.id}, integration: integration}
  end

  describe "another refresh holding the integration's lock" do
    setup %{integration: integration} do
      with_config(:tymeslot, :token_refresh_lock_timeout_ms, 50)
      test_pid = self()

      holder =
        spawn_link(fn ->
          Lock.with_lock(
            Tokens.refresh_lock_key(integration.id),
            fn ->
              send(test_pid, :locked)

              receive do
                :release -> :ok
              end
            end,
            mode: :blocking
          )
        end)

      assert_receive :locked
      on_exit(fn -> send(holder, :release) end)
      :ok
    end

    test "waits while under the bound", %{args: args} do
      assert {:snooze, _seconds} = perform_job(TokenRefreshJob, args, meta: %{"snoozed" => 10})
    end

    test "gives up quietly at the bound", %{args: args} do
      assert {:discard, reason} = perform_job(TokenRefreshJob, args, meta: %{"snoozed" => 11})
      assert TokenRefreshJob.expected_outcome?(reason)
    end
  end

  describe "a rate limit that does not lift" do
    setup do
      stub(GoogleCalendarAPIMock, :refresh_token, fn _integration ->
        {:error, :rate_limited, "Too many requests"}
      end)

      :ok
    end

    test "waits while under the bound", %{args: args} do
      assert {:snooze, _seconds} = perform_job(TokenRefreshJob, args, meta: %{"snoozed" => 10})
    end

    test "fails at the bound, so the remaining attempts back off and end", %{args: args} do
      assert {:error, reason} = perform_job(TokenRefreshJob, args, meta: %{"snoozed" => 11})
      assert reason =~ "rate_limited"
    end
  end
end
