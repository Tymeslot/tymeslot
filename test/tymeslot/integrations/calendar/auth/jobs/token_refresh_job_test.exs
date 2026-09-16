defmodule Tymeslot.Integrations.Calendar.TokenRefreshJobTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.EmailWorker
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

    test "schedules a refresh for an integration flagged for reconnection so its refresh token doesn't lapse" do
      # An integration flagged via flag_for_reconnection/3 for a reason that
      # has nothing to do with its OAuth grant (no calendar selected, a
      # deleted booking calendar) must still have its token refreshed.
      # Microsoft in particular lapses a refresh token after ~90 days of
      # inactivity, so excluding a flagged integration here would leave a
      # dead grant behind by the time the owner gets around to reconnecting.
      # `Tokens.persist_and_return/4` and `handle_refresh_error/3` are what
      # keep `sync_error` intact across the refresh, not this query.
      now = DateTime.utc_now(:second)
      rt_encrypted = Encryption.encrypt("rt")

      g_flagged =
        insert(:calendar_integration,
          provider: "google",
          token_expires_at: DateTime.add(now, 1, :hour),
          refresh_token_encrypted: rt_encrypted,
          is_active: true,
          needs_reauth: true,
          sync_error: "The booking calendar no longer exists on Google."
        )

      o_flagged =
        insert(:calendar_integration,
          provider: "outlook",
          token_expires_at: DateTime.add(now, 30, :minute),
          refresh_token_encrypted: rt_encrypted,
          is_active: true,
          needs_reauth: true,
          sync_error: "The booking calendar no longer exists on Outlook."
        )

      assert :ok = TokenRefreshJob.perform(%Oban.Job{args: %{}})

      assert_enqueued(worker: TokenRefreshJob, args: %{"integration_id" => g_flagged.id})
      assert_enqueued(worker: TokenRefreshJob, args: %{"integration_id" => o_flagged.id})
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

    test "leaves an outstanding needs_reauth flag and its sync_error intact on a successful refresh" do
      # The observed production loop: a sync worker flags an integration whose
      # booking calendar was deleted, the hourly token refresh writes fresh
      # tokens and clears the flag (and the reason) as a side effect, and the
      # sweep picks the integration up again, 404ing every hour, forever.
      integration =
        insert(:calendar_integration,
          provider: "google",
          token_expires_at:
            DateTime.truncate(DateTime.add(DateTime.utc_now(), -1, :hour), :second),
          refresh_token: "rt-123",
          needs_reauth: true,
          sync_error: "The booking calendar no longer exists on Google."
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _refresh_token ->
        {:ok,
         {"new-at", "new-rt",
          DateTime.truncate(DateTime.add(DateTime.utc_now(), 1, :hour), :second)}}
      end)

      assert :ok = TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth

      assert reloaded.sync_error ==
               "The booking calendar no longer exists on Google."
    end

    test "does not overwrite a flagged integration's stored reason with a refresh failure diagnostic" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          is_active: true,
          token_expires_at:
            DateTime.truncate(DateTime.add(DateTime.utc_now(), -1, :hour), :second),
          refresh_token: "rt-123",
          needs_reauth: true,
          sync_error: "The booking calendar no longer exists on Google."
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _refresh_token ->
        {:error, :retryable, "timeout"}
      end)

      assert {:error, _reason} =
               TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth

      assert reloaded.sync_error ==
               "The booking calendar no longer exists on Google."
    end

    test "flags a revoked grant for reconnection and emails the owner instead of deactivating" do
      user = insert(:user)
      integration = insert_expired_google_integration(user)

      expect(GoogleCalendarAPIMock, :refresh_token, fn _integration ->
        {:error, :unauthorized, "Token refresh failed: invalid_grant"}
      end)

      assert {:discard, _job_result} =
               TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})

      updated = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert updated.needs_reauth
      assert updated.is_active
      assert updated.sync_error == ReauthHandling.reauth_error_message(:expired_grant)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_reauth_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "calendar"
        }
      )

      # The health probe only reaches active integrations; deactivating here
      # used to remove it from the one path that could revise the verdict.
      assert integration.id in Enum.map(CalendarIntegrationQueries.list_all_active(), & &1.id)
    end

    test "describes credentials the provider refused for another reason as rejected, not expired" do
      integration = insert_expired_google_integration(insert(:user))

      expect(GoogleCalendarAPIMock, :refresh_token, fn _integration ->
        {:error, :unauthorized, "Token refresh failed: invalid_client"}
      end)

      assert {:discard, _job_result} =
               TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})

      updated = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert updated.needs_reauth
      assert updated.sync_error == ReauthHandling.reauth_error_message(:rejected_credentials)
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

  describe "backoff/1" do
    test "returns expected backoff times" do
      assert TokenRefreshJob.backoff(%Oban.Job{attempt: 1}) == 1
      assert TokenRefreshJob.backoff(%Oban.Job{attempt: 4}) == 300
      assert TokenRefreshJob.backoff(%Oban.Job{attempt: 7}) == 3600
    end

    test "caps at one hour past the final attempt" do
      assert TokenRefreshJob.backoff(%Oban.Job{attempt: 8}) == 3600
    end

    test "keeps the whole schedule inside the 2-hour refresh buffer" do
      total = Enum.sum(Enum.map(1..7, &TokenRefreshJob.backoff(%Oban.Job{attempt: &1})))

      assert total < 2 * 60 * 60
    end
  end

  defp insert_expired_google_integration(user) do
    insert(:calendar_integration,
      user: user,
      provider: "google",
      is_active: true,
      needs_reauth: false,
      token_expires_at: DateTime.truncate(DateTime.add(DateTime.utc_now(), -1, :hour), :second),
      refresh_token: "rt-123"
    )
  end
end
