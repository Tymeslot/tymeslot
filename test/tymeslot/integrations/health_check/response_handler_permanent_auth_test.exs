defmodule Tymeslot.Integrations.HealthCheck.ResponseHandlerPermanentAuthTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.ResponseHandler
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Workers.EmailWorker

  describe "handle_permanent_auth_failure/3" do
    test "flags video integration for reauth and enqueues email on invalid_grant" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, "Connection test failed: Failed to refresh token: invalid_grant"}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == true
      assert updated.is_active == true
      assert updated.sync_error =~ "expired or been revoked"

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "video"
        }
      )
    end

    test "flags calendar integration for reauth and enqueues email on invalid_grant" do
      user = insert(:user)

      integration =
        insert(:calendar_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :calendar,
               integration,
               {:error, "Token refresh failed: invalid_grant"}
             ) == :ok

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == true

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "integration_type" => "calendar"
        }
      )
    end

    test "triggers on atomic :unauthorized error from calendar test_connection" do
      user = insert(:user)

      integration =
        insert(:calendar_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :calendar,
               integration,
               {:error, :unauthorized}
             ) == :ok

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == true
      assert_enqueued(worker: EmailWorker)
    end

    # An expired or revoked OAuth grant has nothing to do with encryption keys.
    # Storing the decryption diagnosis for it sends the user, and support, down
    # the wrong path entirely.
    test "records an expired-grant message rather than a decryption diagnosis on invalid_grant" do
      user = insert(:user)

      integration =
        insert(:calendar_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :calendar,
               integration,
               {:error, "Token refresh failed: invalid_grant"}
             ) == :ok

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)

      assert updated.sync_error ==
               "Access to the connected account has expired or been revoked. Please reconnect the integration."

      refute updated.sync_error =~ "decrypted"
      refute updated.sync_error =~ "encryption key"
    end

    test "records a rejected-credentials message for permanent auth failures other than invalid_grant" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, :unauthorized}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)

      assert updated.sync_error ==
               "The provider rejected the stored credentials for this integration. Please reconnect the integration."

      refute updated.sync_error =~ "decrypted"
    end

    test "ignores transient errors" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, :timeout}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end

    test "ignores rate-limit errors" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, "Rate limited - please try again later"}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end

    test "ignores success results" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:ok, "ok"}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end

    test "Oban uniqueness collapses repeated invocations into a single job" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)
      reason = {:error, "Token refresh failed: invalid_grant"}

      for _i <- 1..5 do
        assert ResponseHandler.handle_permanent_auth_failure(:video, integration, reason) == :ok
      end

      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{
            "action" => "send_integration_unhealthy_notification",
            "user_id" => user.id,
            "integration_id" => integration.id,
            "integration_type" => "video"
          }
        )

      assert length(jobs) == 1
    end

    test "handles non-utf8 error reasons without crashing" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, <<255, 255>>}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end
  end

  describe "permanent_auth_error? matcher — negative cases" do
    # These tests verify that the tokenised whole-word matcher does not fire
    # on strings that contain auth-adjacent words but are not genuine OAuth
    # error codes. Each case must leave `needs_reauth` false and enqueue no
    # email job.

    test "does not trigger on 'User not authorized' (no 'unauthorized' token)" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, "Permission denied: User not authorized to read this calendar"}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end

    test "does not trigger on 'unauthorized origin' (no permanent-auth token in this context)" do
      # "unauthorized" is not in @permanent_auth_error_strings (only atoms handle it);
      # strings like "Network access from unauthorized origin" are CalDAV/Google JS-API
      # errors that do not indicate a revoked OAuth grant and must not force reauth.
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, "Network access from unauthorized origin"}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end

    test "does not trigger on rate-limit errors" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, "Rate limited (HTTP 429)"}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end

    test "does not trigger on 'invalid_grant_period_started' (extended token, not an exact match)" do
      # Tokenised on underscores? No — the regex splits on non-[a-z0-9_] characters,
      # so "invalid_grant_period_started" is a single token and does not equal
      # "invalid_grant". This test guards against substring-style regressions.
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true, needs_reauth: false)

      assert ResponseHandler.handle_permanent_auth_failure(
               :video,
               integration,
               {:error, "Server error: invalid_grant_period_started"}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end
  end
end
