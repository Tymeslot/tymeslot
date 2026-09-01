defmodule Tymeslot.Workers.SlackWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :slack

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Security.Encryption
  alias Tymeslot.Slack.{SlackDeliverySchema, SlackIntegrationSchema}
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker}

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      slack_notifications_allowed: true,
      http_client_module: Tymeslot.HTTPClientMock,
      environment: :test
    )

    :ok
  end

  describe "perform/1 — input validation" do
    test "discards job when integration_id is missing" do
      meeting = insert(:meeting)

      assert {:discard, "Missing required parameters"} =
               perform_job(SlackWorker, %{
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "discards job when meeting_id is missing" do
      integration = insert(:slack_integration)

      assert {:discard, "Missing required parameters"} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created"
               })
    end

    test "discards job with completely empty args" do
      assert {:discard, "Missing required parameters"} = perform_job(SlackWorker, %{})
    end
  end

  describe "perform/1 — successful delivery (oauth mode)" do
    test "delivers message via chat.postMessage and records the delivery" do
      user = insert(:user)
      integration = insert(:slack_integration, user: user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        assert url == "https://slack.com/api/chat.postMessage"
        {:ok, %{status: 200, body: ~s({"ok":true,"ts":"1.2"})}}
      end)

      assert :ok =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(SlackIntegrationSchema, integration.id)
      assert updated.last_triggered_at
      assert updated.failure_count == 0

      delivery = Repo.one(SlackDeliverySchema)
      assert delivery.integration_id == integration.id
      assert delivery.response_status == 200
      assert delivery.delivered_at
      refute delivery.response_body =~ "access_token"
    end

    test "discards job when integration is not found" do
      meeting = insert(:meeting)

      assert {:discard, "Integration or meeting not found"} =
               perform_job(SlackWorker, %{
                 "integration_id" => 999_999,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "discards when integration is paused" do
      user = insert(:user)
      integration = insert(:slack_integration, user: user, is_active: false)
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert {:discard, "Integration is disabled"} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "perform/1 — webhook URL mode" do
    test "delivers via Incoming Webhook URL" do
      user = insert(:user)

      integration =
        insert(:slack_integration,
          user: user,
          app_mode: "webhook_url",
          channel_id: nil,
          bot_token_encrypted: nil,
          webhook_url_encrypted: Encryption.encrypt("https://hooks.slack.com/services/T/B/abc")
        )

      meeting = insert(:meeting, organizer_user_id: user.id)

      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        assert url == "https://hooks.slack.com/services/T/B/abc"
        {:ok, %{status: 200, body: "ok"}}
      end)

      assert :ok =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "auto-disables when Slack returns 404 (webhook URL revoked)" do
      user = insert(:user)

      integration =
        insert(:slack_integration,
          user: user,
          app_mode: "webhook_url",
          channel_id: nil,
          bot_token_encrypted: nil,
          webhook_url_encrypted: Encryption.encrypt("https://hooks.slack.com/services/T/B/abc")
        )

      meeting = insert(:meeting, organizer_user_id: user.id)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 404, body: "no_service"}}
      end)

      assert {:discard, "webhook_url_revoked"} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(SlackIntegrationSchema, integration.id)
      refute updated.is_active
      assert updated.disabled_at
      assert updated.disabled_reason == "webhook_url_revoked"

      delivery = Repo.one(SlackDeliverySchema)
      assert delivery.integration_id == integration.id
      assert delivery.error_message =~ "webhook_url_revoked"
    end
  end

  describe "perform/1 — Slack error handling" do
    setup do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user.id)
      %{user: user, meeting: meeting}
    end

    test "auto-disables on token_revoked", %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"token_revoked"})}}
      end)

      assert {:discard, "token_revoked"} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(SlackIntegrationSchema, integration.id)
      refute updated.is_active
      assert updated.disabled_at
      assert updated.disabled_reason =~ "token_revoked"
    end

    test "auto-disables on account_inactive", %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"account_inactive"})}}
      end)

      assert {:discard, "account_inactive"} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      assert Repo.get(SlackIntegrationSchema, integration.id).disabled_at
    end

    test "auto-disables on channel_not_found", %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"channel_not_found"})}}
      end)

      assert {:discard, "channel_not_found"} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      assert Repo.get(SlackIntegrationSchema, integration.id).disabled_at
    end

    test "snoozes on ratelimited with Retry-After header value", %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 200,
           body: ~s({"ok":false,"error":"ratelimited"}),
           headers: %{"retry-after" => ["12"]}
         }}
      end)

      assert {:snooze, 12} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "snoozes with default 30s when retry_after is absent", %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"ratelimited"})}}
      end)

      assert {:snooze, 30} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "snoozes on a real HTTP 429 (oauth) without counting a failure",
         %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 429, body: "", headers: %{"retry-after" => ["15"]}}}
      end)

      assert {:snooze, 15} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      # Rate limiting must not erode the auto-disable failure budget.
      assert Repo.get(SlackIntegrationSchema, integration.id).failure_count == 0
    end

    test "snoozes on a real HTTP 429 (webhook) without counting a failure",
         %{user: user, meeting: meeting} do
      integration =
        insert(:slack_integration,
          user: user,
          app_mode: "webhook_url",
          channel_id: nil,
          bot_token_encrypted: nil,
          webhook_url_encrypted: Encryption.encrypt("https://hooks.slack.com/services/T/B/abc")
        )

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 429, body: "rate_limited", headers: %{"retry-after" => ["9"]}}}
      end)

      assert {:snooze, 9} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      assert Repo.get(SlackIntegrationSchema, integration.id).failure_count == 0
    end

    test "returns retry-worthy error for other Slack errors", %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"internal_error"})}}
      end)

      assert {:error, "internal_error"} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      delivery = Repo.one(SlackDeliverySchema)
      assert delivery.error_message =~ "internal_error"
      refute delivery.delivered_at
    end

    test "returns error on 5xx HTTP response", %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 503, body: "down"}}
      end)

      assert {:error, {:http_error, 503}} =
               perform_job(
                 SlackWorker,
                 %{
                   "integration_id" => integration.id,
                   "event_type" => "meeting.created",
                   "meeting_id" => meeting.id
                 },
                 attempt: 5
               )

      updated = Repo.get(SlackIntegrationSchema, integration.id)
      assert updated.failure_count == 1
    end

    test "returns transport_error on connection failure", %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert {:error, :transport_error} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      delivery = Repo.one(SlackDeliverySchema)
      assert delivery.error_message =~ "transport_error"
    end
  end

  describe "perform/1 — final-attempt detection after snooze" do
    setup do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user.id)
      %{user: user, meeting: meeting}
    end

    test "does not record a failure on a non-final attempt even past the static 5",
         %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"internal_error"})}}
      end)

      # A snooze bumped max_attempts to 7; attempt 5 is no longer the last.
      assert {:error, "internal_error"} =
               perform_job(
                 SlackWorker,
                 %{
                   "integration_id" => integration.id,
                   "event_type" => "meeting.created",
                   "meeting_id" => meeting.id
                 },
                 attempt: 5,
                 max_attempts: 7
               )

      assert Repo.get(SlackIntegrationSchema, integration.id).failure_count == 0
    end

    test "records a failure exactly once, on the genuine final attempt (max_attempts)",
         %{user: user, meeting: meeting} do
      integration = insert(:slack_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"internal_error"})}}
      end)

      assert {:error, "internal_error"} =
               perform_job(
                 SlackWorker,
                 %{
                   "integration_id" => integration.id,
                   "event_type" => "meeting.created",
                   "meeting_id" => meeting.id
                 },
                 attempt: 7,
                 max_attempts: 7
               )

      assert Repo.get(SlackIntegrationSchema, integration.id).failure_count == 1
    end
  end

  describe "perform/1 — security" do
    test "bot token is never stored in job args" do
      user = insert(:user)
      integration = insert(:slack_integration, user: user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert :ok = SlackWorker.schedule_delivery(integration.id, "meeting.created", meeting.id)

      [job] = all_enqueued(worker: SlackWorker)
      refute Map.has_key?(job.args, "bot_token")
      refute Map.has_key?(job.args, "token")
      refute Map.has_key?(job.args, "encrypted_token")
    end

    test "discards and auto-disables when feature access is revoked" do
      user = insert(:user)
      integration = insert(:slack_integration, user: user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      with_config(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Workers.SlackWorkerTest.DenyAccessChecker
      )

      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        flunk("HTTP client must not be called when access is revoked")
      end)

      assert {:discard, "Insufficient plan"} =
               perform_job(SlackWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(SlackIntegrationSchema, integration.id)
      refute updated.is_active
      assert updated.disabled_reason =~ "Plan no longer permits"
    end
  end

  describe "schedule_delivery/3" do
    test "enqueues an Oban job with the expected arguments" do
      assert :ok = SlackWorker.schedule_delivery(123, "meeting.created", "meeting-uuid")

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => 123,
          "event_type" => "meeting.created",
          "meeting_id" => "meeting-uuid"
        }
      )
    end

    test "deduplicates equivalent jobs within the unique window" do
      assert :ok = SlackWorker.schedule_delivery(42, "meeting.created", "m1")
      assert :ok = SlackWorker.schedule_delivery(42, "meeting.created", "m1")

      jobs = all_enqueued(worker: SlackWorker)
      assert length(jobs) == 1
    end

    # Slack and Telegram integration ids come from separate sequences, so the
    # same id on both sides is the ordinary case rather than a coincidence.
    # With `:worker` left out of the uniqueness comparison that made these two
    # jobs indistinguishable, and whichever arrived second was dropped as a
    # conflict the caller reports as success.
    test "does not deduplicate against a Telegram job carrying the same ids" do
      assert :ok = TelegramWorker.schedule_delivery(7, "meeting.created", "m2")
      assert :ok = SlackWorker.schedule_delivery(7, "meeting.created", "m2")

      assert [_telegram] = all_enqueued(worker: TelegramWorker)
      assert [_slack] = all_enqueued(worker: SlackWorker)
    end
  end
end

defmodule Tymeslot.Workers.SlackWorkerTest.DenyAccessChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: {:error, :insufficient_plan}
end
