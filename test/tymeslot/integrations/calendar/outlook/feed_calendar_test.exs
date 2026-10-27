defmodule Tymeslot.Integrations.Calendar.Outlook.FeedCalendarTest do
  @moduledoc """
  An Outlook row cached under a label that names no calendar in the
  integration's list (`"primary"` from an earlier delta, or the booking
  calendar's id from an earlier bootstrap) is invisible to the grid's
  per-calendar selection and misses its calendar's colour. One feed read
  files it under the default calendar the feed covers.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.CalendarAppearanceSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync
  alias Tymeslot.Integrations.Calendar.Outlook.FeedCalendar
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :set_mox_global
  setup :verify_on_exit!

  @default "AAMkDefault"
  @booking "AAMkBooking"

  setup do
    user = insert(:user)

    inserted =
      insert(:calendar_integration,
        user: user,
        provider: "outlook",
        is_active: true,
        default_booking_calendar_id: @booking,
        access_token_encrypted: Encryption.encrypt("token"),
        refresh_token_encrypted: Encryption.encrypt("refresh"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        last_full_sync_at: DateTime.utc_now(:second),
        graph_delta_link:
          "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old",
        calendar_list: [
          %{id: @default, name: "Calendar", primary: true, selected: true},
          %{id: @booking, name: "Bookings", primary: false, selected: false}
        ]
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)

    from_delta = cached(integration, "standup@x", "primary")
    from_bootstrap = cached(integration, "review@x", @booking)

    %{user: user, integration: integration, rows: [from_delta, from_bootstrap]}
  end

  defp cached(integration, uid, label) do
    start = DateTime.add(DateTime.utc_now(:second), 1, :day)

    insert(:provider_calendar_event,
      calendar_integration: integration,
      uid: uid,
      provider_event_id: "graph-" <> uid,
      provider_calendar_id: label,
      summary: "Team " <> uid,
      start_at: start,
      end_at: DateTime.add(start, 3600, :second)
    )
  end

  defp searched(user, integration) do
    {:ok, fresh} = CalendarIntegrationQueries.get(integration.id)
    user.id |> CalendarGrid.search_events("Team", [fresh]) |> Enum.map(& &1.uid) |> Enum.sort()
  end

  # A delta that returns the bootstrap's mislabelled row as changed, and
  # nothing about the delta's own.
  defp sync_once(integration) do
    start = DateTime.add(DateTime.utc_now(:second), 1, :day)

    body =
      Jason.encode!(%{
        "value" => [
          %{
            "id" => "graph-review@x",
            "iCalUId" => "review@x",
            "subject" => "Team review@x",
            "start" => %{"dateTime" => DateTime.to_iso8601(start), "timeZone" => "UTC"},
            "end" => %{
              "dateTime" => start |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
              "timeZone" => "UTC"
            }
          }
        ],
        "@odata.deltaLink" =>
          "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
      })

    expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
      {:ok, %{status: 200, body: body}}
    end)

    assert :ok = DeltaSync.fetch_and_apply(integration)
  end

  test "the feed is the default calendar discovery listed", %{integration: integration} do
    assert FeedCalendar.id(integration) == @default
  end

  test "a mislabelled row becomes visible and takes its calendar's colour after one sync", %{
    user: user,
    integration: integration
  } do
    assert searched(user, integration) == []

    sync_once(integration)

    assert searched(user, integration) == ["review@x", "standup@x"]

    colours =
      CalendarGrid.calendar_colour_classes([
        %CalendarAppearanceSchema{
          calendar_integration_id: integration.id,
          provider_calendar_id: @default,
          colour: "peacock"
        }
      ])

    labels =
      Repo.all(
        from e in ProviderCalendarEventSchema,
          where: e.calendar_integration_id == ^integration.id,
          select: {e.calendar_integration_id, e.provider_calendar_id}
      )

    assert labels != []
    assert Enum.all?(labels, &Map.has_key?(colours, &1))
  end

  test "a row the grid created in another calendar keeps its label", %{
    integration: integration
  } do
    elsewhere = cached(integration, "lunch@x", "AAMkSomewhereElse")

    sync_once(integration)

    assert Repo.reload!(elsewhere).provider_calendar_id == "AAMkSomewhereElse"
  end
end
