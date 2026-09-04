defmodule Tymeslot.Integrations.Calendar.SyncOwnershipFlagTest do
  @moduledoc """
  Ownership flagging on the full-refresh write path.

  `Sync.persist_normalised_events/2` is covered in `SyncTest`; this is the
  other path into the cache. Exchange reaches the cache through
  `full_refresh_for_role/3` alone and never calls `persist_normalised_events/2`,
  so ownership has to be resolved here too or a booking mirrored to an Exchange
  calendar stays unowned forever.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :unit

  alias Ecto.UUID
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync

  describe "full_refresh_for_role/3" do
    # Exchange reaches the cache through this function alone — it never calls
    # `persist_normalised_events/2` — so ownership has to be resolved here too
    # or a booking mirrored to an Exchange calendar stays unowned forever.
    defp exchange_event(integration, uid, start_time) do
      CalendarEvent.new!(%{
        uid: uid,
        calendar_integration_id: integration.id,
        provider: :exchange,
        provider_calendar_id: "primary",
        provider_event_id: "AAMkAD#{System.unique_integer([:positive])}",
        all_day: false,
        start_at: start_time,
        end_at: DateTime.add(start_time, 3600, :second),
        synced_at: DateTime.utc_now(:microsecond)
      })
    end

    test "flags a mirrored booking as ours" do
      integration = insert(:calendar_integration)
      start_time = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      # A booking's UID is a bare UUID, and Exchange stamps no marker of its
      # own, so the link to the meeting is the only thing that identifies it.
      uid = UUID.generate()

      insert(:meeting,
        calendar_integration_id: integration.id,
        provider_event_id: nil,
        uid: uid,
        start_time: start_time
      )

      event = exchange_event(integration, uid, start_time)
      refute event.created_by_tymeslot

      {:ok, 1} = Sync.full_refresh_for_role(integration, "display_only", [event])

      {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
      assert cached.created_by_tymeslot
    end

    test "leaves an event with no matching meeting unflagged" do
      integration = insert(:calendar_integration)
      start_time = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      uid = UUID.generate()

      event = exchange_event(integration, uid, start_time)

      {:ok, 1} = Sync.full_refresh_for_role(integration, "display_only", [event])

      {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
      refute cached.created_by_tymeslot
    end

    test "flags only the booking among a mixed batch" do
      integration = insert(:calendar_integration)
      start_time = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      booking_uid = UUID.generate()
      foreign_uid = UUID.generate()

      insert(:meeting,
        calendar_integration_id: integration.id,
        provider_event_id: nil,
        uid: booking_uid,
        start_time: start_time
      )

      {:ok, 2} =
        Sync.full_refresh_for_role(integration, "display_only", [
          exchange_event(integration, booking_uid, start_time),
          exchange_event(integration, foreign_uid, start_time)
        ])

      {:ok, ours} = ProviderCalendarEventQueries.get_by_uid(integration.id, booking_uid)
      {:ok, theirs} = ProviderCalendarEventQueries.get_by_uid(integration.id, foreign_uid)

      assert ours.created_by_tymeslot
      refute theirs.created_by_tymeslot
    end
  end
end
