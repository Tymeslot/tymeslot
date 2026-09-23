defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventQueriesLocalEditTest do
  @moduledoc """
  `ProviderCalendarEventQueries.apply_local_edit/3` writes only the columns a
  dashboard edit can change, so a local edit never wipes what the provider
  owns on the cached row.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  describe "apply_local_edit/3" do
    setup do
      integration = insert(:calendar_integration, user: insert(:user))
      video_integration = insert(:video_integration, user: integration.user)

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "occurrence-uid",
          summary: "Standup",
          start_at: ~U[2026-06-01 09:00:00.000000Z],
          end_at: ~U[2026-06-01 09:30:00.000000Z],
          recurring_event_id: "series-uid",
          etag: "\"etag-1\"",
          raw_ical: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
          organiser: %{"email" => "owner@example.com"},
          timezone: "Europe/London",
          sync_state: "synced",
          synced_at: ~U[2026-05-01 00:00:00.000000Z]
        )

      %{integration: integration, event: event, video_integration: video_integration}
    end

    test "writes every editable column", %{
      integration: integration,
      video_integration: video_integration
    } do
      attrs = %{
        summary: "Renamed",
        description: "Agenda",
        location: "Room 2",
        start_at: nil,
        end_at: nil,
        all_day: true,
        start_date: ~D[2026-06-02],
        end_date: ~D[2026-06-03],
        reminders: [%{"minutes" => 10}],
        recurrence_rule: "FREQ=DAILY",
        colour: "#ff0000",
        attendees: [%{"email" => "guest@example.com"}],
        video_link: "https://video.example.com/room",
        video_integration_id: video_integration.id
      }

      assert {:ok, _updated} =
               ProviderCalendarEventQueries.apply_local_edit(
                 integration.id,
                 "occurrence-uid",
                 attrs
               )

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "occurrence-uid")
      assert Map.take(row, Map.keys(attrs)) == attrs
    end

    test "leaves provider-owned columns untouched", %{integration: integration, event: event} do
      assert {:ok, _updated} =
               ProviderCalendarEventQueries.apply_local_edit(integration.id, event.uid, %{
                 summary: "Renamed",
                 start_at: ~U[2026-06-01 10:00:00Z],
                 end_at: ~U[2026-06-01 10:30:00Z]
               })

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Renamed"
      assert row.start_at == ~U[2026-06-01 10:00:00.000000Z]
      assert row.recurring_event_id == "series-uid"
      assert row.etag == event.etag
      assert row.raw_ical == event.raw_ical
      assert row.organiser == %{"email" => "owner@example.com"}
      assert row.timezone == "Europe/London"
      assert row.synced_at == event.synced_at
    end

    test "ignores keys outside the editable columns", %{integration: integration, event: event} do
      assert {:ok, _updated} =
               ProviderCalendarEventQueries.apply_local_edit(integration.id, event.uid, %{
                 location: "Room 9",
                 etag: "\"forged\"",
                 recurring_event_id: nil,
                 sync_state: "locally_modified",
                 provider_event_id: "other",
                 not_a_column: "ignored"
               })

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.location == "Room 9"
      assert row.etag == event.etag
      assert row.recurring_event_id == "series-uid"
      assert row.sync_state == "synced"
      assert row.provider_event_id == event.provider_event_id
    end

    test "returns :not_found when no row matches", %{integration: integration, event: event} do
      assert {:error, :not_found} =
               ProviderCalendarEventQueries.apply_local_edit(integration.id, "missing-uid", %{
                 summary: "Nope"
               })

      other_integration = insert(:calendar_integration, user: integration.user)

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.apply_local_edit(other_integration.id, event.uid, %{
                 summary: "Nope"
               })
    end

    test "returns the changeset for a video integration that does not exist", %{
      integration: integration,
      event: event
    } do
      assert {:error, %Ecto.Changeset{errors: [video_integration_id: _error]}} =
               ProviderCalendarEventQueries.apply_local_edit(integration.id, event.uid, %{
                 video_integration_id: -1
               })
    end
  end
end
