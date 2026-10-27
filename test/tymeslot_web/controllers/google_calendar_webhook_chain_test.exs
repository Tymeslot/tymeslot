defmodule TymeslotWeb.GoogleCalendarWebhookChainTest do
  @moduledoc """
  The whole path of a Google Calendar push notification: the webhook enqueues
  `SyncGoogleCalendarWorker`, the job runs a sync cycle against Google, and the
  event Google reports as changed is what Tymeslot's event cache now holds.
  The enqueue alone is covered in `GoogleCalendarWebhookControllerTest`.
  """

  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :calendar

  import Ecto.Query
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  # A series' rule is read from its recurring event; these events are single.
  setup do
    stub(GoogleCalendarAPIMock, :get_series_master, fn _integration, _calendar, _master ->
      {:error, :not_found, "Not found"}
    end)

    :ok
  end

  # An hour-long event, so the times stay ahead of the suite whenever it runs.
  defp google_event(summary, start_at) do
    %{
      "id" => "push-event-1",
      "iCalUID" => "push-event-1@google.com",
      "summary" => summary,
      "status" => "confirmed",
      "start" => %{"dateTime" => DateTime.to_iso8601(start_at)},
      "end" => %{"dateTime" => start_at |> DateTime.add(1, :hour) |> DateTime.to_iso8601()},
      "attendees" => []
    }
  end

  defp days_ahead(days, hour) do
    Date.utc_today() |> Date.add(days) |> DateTime.new!(Time.new!(hour, 0, 0))
  end

  test "a push notification leads to the changed event being visible in the cache", %{conn: conn} do
    integration =
      insert(:calendar_integration,
        provider: "google",
        google_sync_token: "token-0",
        google_channel_id: "chain-channel",
        google_channel_secret: "chain-secret"
      )

    # The event as Tymeslot already knows it, from an earlier sync.
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok,
       %{
         events: [google_event("Design review", days_ahead(30, 9))],
         next_sync_token: "token-1"
       }}
    end)

    assert :ok =
             perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})

    assert %{summary: "Design review"} = cached_event(integration)

    # The owner moves and renames it in Google Calendar; Google pushes.
    conn =
      conn
      |> put_req_header("x-goog-channel-id", "chain-channel")
      |> put_req_header("x-goog-channel-token", "chain-secret")
      |> post("/webhooks/google-calendar")

    assert conn.status == 200

    assert [job] =
             all_enqueued(
               worker: SyncGoogleCalendarWorker,
               args: %{"calendar_integration_id" => integration.id}
             )

    moved_start = days_ahead(31, 14)

    # The delta runs from the token the earlier sync stored.
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn %{google_sync_token: token} ->
      assert token == "token-1"

      {:ok,
       %{
         events: [google_event("Design review (moved)", moved_start)],
         next_sync_token: "token-2"
       }}
    end)

    assert :ok = perform_job(SyncGoogleCalendarWorker, job.args)

    cached = cached_event(integration)
    assert cached.summary == "Design review (moved)"
    assert DateTime.compare(cached.start_at, moved_start) == :eq
    assert DateTime.compare(cached.end_at, DateTime.add(moved_start, 1, :hour)) == :eq

    assert Repo.get!(CalendarIntegrationSchema, integration.id).google_sync_token == "token-2"
  end

  # One row per event: the change replaces the cached copy, it does not add one.
  defp cached_event(integration) do
    Repo.one!(
      from(e in ProviderCalendarEventSchema,
        where: e.calendar_integration_id == ^integration.id
      )
    )
  end
end
