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

  defp google_event(summary, start_iso, end_iso) do
    %{
      "id" => "push-event-1",
      "iCalUID" => "push-event-1@google.com",
      "summary" => summary,
      "status" => "confirmed",
      "start" => %{"dateTime" => start_iso},
      "end" => %{"dateTime" => end_iso},
      "attendees" => []
    }
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
         events: [google_event("Design review", "2030-04-10T09:00:00Z", "2030-04-10T10:00:00Z")],
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

    # The delta runs from the token the earlier sync stored.
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn %{google_sync_token: token} ->
      assert token == "token-1"

      {:ok,
       %{
         events: [
           google_event("Design review (moved)", "2030-04-11T14:00:00Z", "2030-04-11T15:00:00Z")
         ],
         next_sync_token: "token-2"
       }}
    end)

    assert :ok = perform_job(SyncGoogleCalendarWorker, job.args)

    cached = cached_event(integration)
    assert cached.summary == "Design review (moved)"
    assert DateTime.compare(cached.start_at, ~U[2030-04-11 14:00:00Z]) == :eq
    assert DateTime.compare(cached.end_at, ~U[2030-04-11 15:00:00Z]) == :eq

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
