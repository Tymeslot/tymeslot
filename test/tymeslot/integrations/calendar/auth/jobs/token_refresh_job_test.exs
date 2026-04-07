defmodule Tymeslot.Integrations.Calendar.TokenRefreshJobTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  import Tymeslot.Factory
  import Mox

  setup :verify_on_exit!

  describe "perform/1 - bulk refresh" do
    test "schedules individual refreshes for expiring tokens" do
      now = DateTime.utc_now(:second)
      rt_encrypted = Encryption.encrypt("rt")

      # Google token expiring soon (1 hour from now)
      g_integration =
        insert(:calendar_integration,
          provider: "google",
          token_expires_at: DateTime.add(now, 1, :hour),
          refresh_token_encrypted: rt_encrypted,
          is_active: true
        )

      # Outlook token expiring soon (30 mins from now)
      o_integration =
        insert(:calendar_integration,
          provider: "outlook",
          token_expires_at: DateTime.add(now, 30, :minute),
          refresh_token_encrypted: rt_encrypted,
          is_active: true
        )

      # Token NOT expiring soon (5 hours from now)
      insert(:calendar_integration,
        provider: "google",
        token_expires_at: DateTime.add(now, 5, :hour),
        refresh_token_encrypted: rt_encrypted,
        is_active: true
      )

      assert :ok = TokenRefreshJob.perform(%Oban.Job{args: %{}})

      # Should have 2 jobs in the queue
      assert_enqueued(worker: TokenRefreshJob, args: %{"integration_id" => g_integration.id})
      assert_enqueued(worker: TokenRefreshJob, args: %{"integration_id" => o_integration.id})
    end
  end

  describe "perform/1 - individual refresh" do
    test "refreshes token successfully" do
      # Token must be expired to trigger refresh
      integration =
        insert(:calendar_integration,
          provider: "google",
          token_expires_at:
            DateTime.truncate(DateTime.add(DateTime.utc_now(), -1, :hour), :second),
          refresh_token: "rt-123"
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _refresh_token ->
        {:ok,
         {"new-at", "new-rt",
          DateTime.truncate(DateTime.add(DateTime.utc_now(), 1, :hour), :second)}}
      end)

      assert :ok = TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})
    end

    test "handles permanent errors by deactivating integration" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          is_active: true,
          token_expires_at:
            DateTime.truncate(DateTime.add(DateTime.utc_now(), -1, :hour), :second),
          refresh_token: "rt-123"
        )

      # invalid_grant is a permanent error
      expect(GoogleCalendarAPIMock, :refresh_token, fn _refresh_token ->
        {:error, :permanent, "invalid_grant"}
      end)

      assert {:discard, _job_result} =
               TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})

      updated =
        Repo.get(CalendarIntegrationSchema, integration.id)

      refute updated.is_active
      assert updated.sync_error =~ "PERMANENT"
    end

    test "handles retryable errors" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          token_expires_at:
            DateTime.truncate(DateTime.add(DateTime.utc_now(), -1, :hour), :second),
          refresh_token: "rt-123"
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _refresh_token ->
        {:error, :retryable, "timeout"}
      end)

      assert {:error, _reason} =
               TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})
    end
  end

  describe "custom_backoff/1" do
    test "returns expected backoff times" do
      assert TokenRefreshJob.custom_backoff(1) == 1
      assert TokenRefreshJob.custom_backoff(4) == 300
      assert TokenRefreshJob.custom_backoff(7) == 3600
    end
  end
end
