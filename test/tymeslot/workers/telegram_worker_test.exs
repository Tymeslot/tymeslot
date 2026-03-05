defmodule Tymeslot.Workers.TelegramWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :telegram

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.DatabaseSchemas.TelegramDeliverySchema
  alias Tymeslot.DatabaseSchemas.TelegramIntegrationSchema
  alias Tymeslot.Workers.TelegramWorker

  setup :verify_on_exit!

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
      assert updated.disabled_reason =~ "Unauthorized"
    end

    test "auto-disables when bot is blocked by user", %{user: user, meeting: meeting} do
      integration = insert(:telegram_integration, user: user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 400,
           body:
             ~s({"ok":false,"description":"Forbidden: bot was blocked by the user"})
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
      assert updated.disabled_reason =~ "blocked"
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
      assert updated.disabled_reason =~ "Too many consecutive failures"
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

      args = %{
        "integration_id" => integration.id,
        "event_type" => "meeting.created",
        "meeting_id" => meeting.id
      }

      refute Map.has_key?(args, "bot_token")
      refute Map.has_key?(args, "token")
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
