defmodule Tymeslot.Workers.TelegramWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :telegram

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Telegram.TelegramDeliverySchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Workers.TelegramWorker

  setup :verify_on_exit!
  setup :capture_admin_alerts

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      environment: :test
    )

    :ok
  end

  describe "perform/1 - input validation" do
    test "discards job when integration_id is missing" do
      meeting = insert(:meeting)

      assert {:discard, "Missing required parameters"} =
               perform_job(TelegramWorker, %{
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "discards job when meeting_id is missing" do
      integration = insert(:telegram_integration)

      assert {:discard, "Missing required parameters"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created"
               })
    end

    test "discards job when event_type is missing" do
      meeting = insert(:meeting)
      integration = insert(:telegram_integration)

      assert {:discard, "Missing required parameters"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "meeting_id" => meeting.id
               })
    end

    test "discards job with completely empty args" do
      assert {:discard, "Missing required parameters"} = perform_job(TelegramWorker, %{})
    end
  end

  describe "perform/1 - successful delivery" do
    test "delivers message and records success" do
      user = insert(:user)
      integration = insert(:telegram_integration, user: user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      expect_http_success()

      assert :ok =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      assert updated.last_triggered_at
      assert updated.failure_count == 0

      delivery = Repo.one(TelegramDeliverySchema)
      assert delivery.integration_id == integration.id
      assert delivery.response_status == 200
      assert delivery.delivered_at
    end

    test "discards job if integration not found" do
      meeting = insert(:meeting)

      assert {:discard, "Integration or meeting not found"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => 999_999,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "discards job if integration is disabled" do
      user = insert(:user)
      integration = insert(:telegram_integration, user: user, is_active: false)
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert {:discard, "Integration is disabled"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "perform/1 - error handling" do
    setup do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user.id)
      %{user: user, meeting: meeting}
    end

    test "records failure on 5xx error", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "Internal Server Error"}}
      end)

      assert {:error, {:http_error, 500}} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      assert updated.failure_count == 1
    end

    test "auto-disables on 401 unauthorized", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: ~s({"ok":false,"description":"Unauthorized"})}}
      end)

      assert {:discard, "Unauthorized"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      refute updated.is_active
      assert updated.disabled_at
      assert updated.disabled_reason == "invalid_token"
    end

    # A shared bot token is used by every user on the deployment, so a 401
    # against it is the operator's credential failing, not a per-integration
    # fault. Auto-disabling here would silently and permanently disable
    # Telegram for every user, one integration at a time.
    test "does not auto-disable a shared-mode integration on 401, and alerts instead",
         %{user: user, meeting: meeting} do
      setup_config(:tymeslot, telegram_bot_token: "shared_token_123")
      integration = insert(:telegram_integration, user: user, bot_mode: "shared")

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: ~s({"ok":false,"description":"Unauthorized"})}}
      end)

      assert {:discard, "Unauthorized"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      assert_receive {:send_alert, :integration_health_failure, payload}
      assert payload.integration_id == integration.id

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      assert updated.is_active
      refute updated.disabled_at
      refute updated.disabled_reason
    end

    # A job that burned attempt 1 on an unrelated transient failure and only
    # reaches the shared-token 401 on attempt 2+ must not lose its alert: this
    # path always discards, so nothing else raises it for this job.
    test "alerts on a shared-mode 401 even when it is not the job's first attempt",
         %{user: user, meeting: meeting} do
      setup_config(:tymeslot, telegram_bot_token: "shared_token_123")
      integration = insert(:telegram_integration, user: user, bot_mode: "shared")

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: ~s({"ok":false,"description":"Unauthorized"})}}
      end)

      assert {:discard, "Unauthorized"} =
               perform_job(
                 TelegramWorker,
                 %{
                   "integration_id" => integration.id,
                   "event_type" => "meeting.created",
                   "meeting_id" => meeting.id
                 },
                 attempt: 2
               )

      assert_receive {:send_alert, :integration_health_failure, payload}
      assert payload.integration_id == integration.id
    end

    # Telegram answers a blocked bot with 403, and derives the body's
    # `Forbidden:` prefix from that same code — the 400/`Forbidden:` pairing
    # this test used to assert is one the API cannot emit, so it passed while
    # every real block fell through to the retry-then-discard catch-all and
    # the integration was never disabled.
    test "auto-disables when bot is blocked by user", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 403,
           body: ~s({"ok":false,"description":"Forbidden: bot was blocked by the user"})
         }}
      end)

      assert {:discard, "Bot blocked"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      refute updated.is_active
      assert updated.disabled_reason == "bot_blocked"
    end

    test "auto-disables when the bot is kicked from the group", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 403,
           body: ~s({"ok":false,"description":"Forbidden: bot was kicked from the group chat"})
         }}
      end)

      assert {:discard, "Bot kicked"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      refute updated.is_active
      assert updated.disabled_reason == "bot_kicked"
    end

    # Unlike a 401, a per-chat block/kick is specific to this integration's
    # chat, not the credential, so it stays a genuine reason to auto-disable
    # even when the bot token is shared across the deployment.
    test "still auto-disables a shared-mode integration when the bot is blocked",
         %{user: user, meeting: meeting} do
      setup_config(:tymeslot, telegram_bot_token: "shared_token_123")
      integration = insert(:telegram_integration, user: user, bot_mode: "shared")

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 403,
           body: ~s({"ok":false,"description":"Forbidden: bot was blocked by the user"})
         }}
      end)

      assert {:discard, "Bot blocked"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      refute updated.is_active
      assert updated.disabled_reason == "bot_blocked"
    end

    test "leaves the integration active on a 403 that is not a block or kick",
         %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 403,
           body: ~s({"ok":false,"description":"Forbidden: message can't be sent"})
         }}
      end)

      assert {:error, {:bad_request, _description}} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      assert Repo.get(TelegramIntegrationSchema, integration.id).is_active
    end

    test "auto-disables on other permanent per-chat rejections", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 400,
           body: ~s({"ok":false,"description":"Bad Request: chat not found"})
         }}
      end)

      assert {:discard, "Chat unreachable"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      refute updated.is_active
      assert updated.disabled_reason == "chat_unreachable"
    end

    test "rewrites the chat id after a supergroup upgrade and lets Oban retry",
         %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user, chat_id: "-100111")

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 400,
           body:
             ~s({"ok":false,"description":"Bad Request: group chat was upgraded to a supergroup chat","parameters":{"migrate_to_chat_id":-100222}})
         }}
      end)

      assert {:error, {:chat_migrated, -100_222}} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      assert updated.chat_id == "-100222"
      assert updated.is_active
    end

    test "snoozes on 429 rate limit with retry_after", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 429,
           body:
             ~s({"ok":false,"description":"Too Many Requests","parameters":{"retry_after":10}})
         }}
      end)

      assert {:snooze, 10} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "clamps an absurd retry_after into a sane range", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 429,
           body:
             ~s({"ok":false,"description":"Too Many Requests","parameters":{"retry_after":999999}})
         }}
      end)

      assert {:snooze, 300} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "discards instead of snoozing forever once the rate-limit budget is spent",
         %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 429,
           body:
             ~s({"ok":false,"description":"Too Many Requests","parameters":{"retry_after":10}})
         }}
      end)

      assert {:discard, "Rate limited too many times"} =
               perform_job(
                 TelegramWorker,
                 %{
                   "integration_id" => integration.id,
                   "event_type" => "meeting.created",
                   "meeting_id" => meeting.id
                 },
                 attempt: 20
               )

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      assert updated.failure_count == 1
    end

    test "records the failure once, not again on an execution that follows a snooze", %{
      user: user,
      meeting: meeting
    } do
      integration = insert(:telegram_integration, user: user, failure_count: 0)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "Error"}}
      end)

      # A job that snoozed past a 429 comes back with `attempt` rolled back
      # from Oban 2.24 on, so `attempt == 1` is true again on the execution
      # after it. The failure budget feeding auto-disable is meant to count
      # this job once, so the second execution must not record a second one.
      assert {:error, {:http_error, 500}} =
               perform_job(
                 TelegramWorker,
                 %{
                   "integration_id" => integration.id,
                   "event_type" => "meeting.created",
                   "meeting_id" => meeting.id
                 },
                 attempt: 1,
                 meta: %{"snoozed" => 1}
               )

      assert Repo.get(TelegramIntegrationSchema, integration.id).failure_count == 0
    end

    test "auto-disables after 10 consecutive failures", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user, failure_count: 9)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "Error"}}
      end)

      assert {:error, {:http_error, 500}} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      assert updated.failure_count == 10
      refute updated.is_active
      assert updated.disabled_at
      assert updated.disabled_reason == "too_many_failures"
    end

    test "records failure on retry attempts (not just attempt 1)", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user, failure_count: 2)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "Internal Server Error"}}
      end)

      # Simulate this being attempt 3 of 5
      assert {:error, {:http_error, 500}} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated = Repo.get(TelegramIntegrationSchema, integration.id)
      assert updated.failure_count == 3
    end

    test "handles connection timeout", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %{reason: :timeout}}
      end)

      assert {:error, reason} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      assert inspect(reason) =~ "timeout"

      delivery = Repo.one(TelegramDeliverySchema)
      assert delivery.error_message =~ "timeout"
      refute delivery.delivered_at
    end
  end

  describe "perform/1 - security" do
    test "bot token is never stored in job args" do
      user = insert(:user)
      integration = insert(:telegram_integration, user: user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert :ok = TelegramWorker.schedule_delivery(integration.id, "meeting.created", meeting.id)

      [job] = all_enqueued(worker: TelegramWorker)
      refute Map.has_key?(job.args, "bot_token")
      refute Map.has_key?(job.args, "token")
      refute Map.has_key?(job.args, "encrypted_token")
    end

    test "discards job when feature access is revoked" do
      user = insert(:user)
      integration = insert(:telegram_integration, user: user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      with_config(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Workers.TelegramWorkerTest.DenyAccessChecker
      )

      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        flunk("HTTP client should not be called when access is revoked")
      end)

      assert {:discard, "Insufficient plan"} =
               perform_job(TelegramWorker, %{
                 "integration_id" => integration.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "schedule_delivery/3" do
    test "enqueues an Oban job with correct arguments" do
      assert :ok = TelegramWorker.schedule_delivery(123, "meeting.created", "meeting-uuid-123")

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => 123,
          "event_type" => "meeting.created",
          "meeting_id" => "meeting-uuid-123"
        }
      )
    end
  end
end

defmodule Tymeslot.Workers.TelegramWorkerTest.DenyAccessChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: {:error, :insufficient_plan}
end
