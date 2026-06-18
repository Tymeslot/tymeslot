defmodule Tymeslot.Integrations.CalendarManagementTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup :verify_on_exit!

  # ---------------------------------------------------------------------------
  # toggle_calendar_integration/1
  # ---------------------------------------------------------------------------

  describe "toggle_calendar_integration/1" do
    test "enqueues an IntegrationHealthWorker probe when reactivating (inactive → active)" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: false)

      assert {:ok, updated} = CalendarManagement.toggle_calendar_integration(integration)
      assert updated.is_active

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end

    test "does NOT enqueue a probe when deactivating (active → inactive)" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert {:ok, updated} = CalendarManagement.toggle_calendar_integration(integration)
      refute updated.is_active

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # update_calendar_integration/2
  # ---------------------------------------------------------------------------

  describe "update_calendar_integration/2" do
    test "enqueues an IntegrationHealthWorker probe and resets the health row when credential fields are present" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # Seed an unhealthy row so we can verify the reset fires.
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: "calendar",
        integration_id: integration.id,
        user_id: user.id,
        status: "unhealthy",
        failures: 5,
        consecutive_hard_failures: 5,
        successes: 0,
        backoff_ms: :timer.hours(1)
      })
      |> Repo.insert!()

      assert {:ok, _updated} =
               CalendarManagement.update_calendar_integration(integration, %{
                 password_encrypted: "new-encrypted-password"
               })

      # Health row is reset to a healthy baseline.
      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert row.status == "healthy"
      assert row.failures == 0

      # Immediate verification probe is enqueued.
      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end

    test "does NOT enqueue a probe when no credential fields are present" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, name: "Before")

      assert {:ok, _updated} =
               CalendarManagement.update_calendar_integration(integration, %{name: "After"})

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # mark_sync_success/1
  # ---------------------------------------------------------------------------

  describe "mark_sync_success/1" do
    test "resets the health state row without enqueueing a probe" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # Seed an unhealthy row.
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: "calendar",
        integration_id: integration.id,
        user_id: user.id,
        status: "unhealthy",
        failures: 3,
        consecutive_hard_failures: 3,
        successes: 0,
        backoff_ms: :timer.hours(1)
      })
      |> Repo.insert!()

      assert {:ok, _updated} = CalendarManagement.mark_sync_success(integration)

      # Health row is reset to a healthy baseline.
      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert row.status == "healthy"
      assert row.failures == 0

      # A successful sync proves health — no redundant probe should be enqueued.
      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # create_calendar_integration/1
  # ---------------------------------------------------------------------------

  @propfind_calendar_response """
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/calendars/user/personal/</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname>Personal</D:displayname>
          <D:resourcetype>
            <D:collection/>
            <C:calendar/>
          </D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  describe "create_calendar_integration/1" do
    test "emits [:tymeslot, :calendar, :connected] telemetry with provider on success" do
      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: @propfind_calendar_response}}
      end)

      user = insert(:user)
      _profile = insert(:profile, user: user)

      attrs = %{
        user_id: user.id,
        name: "My CalDAV",
        provider: "caldav",
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider_account_id: "https://caldav.example.com||user",
        is_active: true
      }

      test_pid = self()

      :telemetry.attach(
        "test-calendar-connected",
        [:tymeslot, :calendar, :connected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-calendar-connected") end)

      assert {:ok, _integration} = CalendarManagement.create_calendar_integration(attrs)
      assert_received {:telemetry, %{count: 1}, %{provider: provider}}
      assert is_binary(provider)
    end
  end
end
