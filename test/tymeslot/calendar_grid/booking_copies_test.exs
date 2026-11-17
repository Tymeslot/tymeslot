defmodule Tymeslot.CalendarGrid.BookingCopiesTest do
  @moduledoc """
  Which events of a window are the calendar copies of Tymeslot bookings,
  asked of the whole window at once: the answer must be the one
  `EventDeletion.booking_copy?/1` gives event by event, and drawing a window
  must cost one meetings query however many events it holds.
  """

  # The query handler is global, so a concurrent test would add its own reads.
  use Tymeslot.DataCase, async: false

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.EventPayload

  setup do
    user = insert(:user)

    insert(:calendar_integration,
      user: user,
      provider: "google",
      is_active: true,
      calendar_list: [%{"id" => "work", "name" => "Work", "selected" => true}]
    )

    [integration] = CalendarGrid.list_active_integrations(user.id)
    other = insert(:calendar_integration, user: user, provider: "google")

    insert(:meeting,
      organizer_user: user,
      calendar_integration_id: integration.id,
      calendar_uid: "copy-by-uid"
    )

    insert(:meeting,
      organizer_user: user,
      calendar_integration_id: integration.id,
      provider_event_id: "copy-by-id",
      start_time: ~U[2026-10-20 09:00:00Z],
      end_time: ~U[2026-10-20 09:30:00Z]
    )

    # Linked, but on another integration: not a copy of anything on this one.
    insert(:meeting,
      organizer_user: user,
      calendar_integration_id: other.id,
      calendar_uid: "elsewhere",
      start_time: ~U[2026-10-21 09:00:00Z],
      end_time: ~U[2026-10-21 09:30:00Z]
    )

    events = [
      event(integration, 1, uid: "copy-by-uid"),
      event(integration, 2, provider_event_id: "copy-by-id"),
      event(integration, 3, uid: "ordinary", provider_event_id: "ordinary-id"),
      event(integration, 4, uid: "elsewhere"),
      event(integration, 5, [])
    ]

    %{integration: integration, events: events}
  end

  defp event(integration, id, attrs) do
    Map.merge(
      %{
        id: id,
        uid: nil,
        provider_event_id: nil,
        calendar_integration_id: integration.id,
        provider_calendar_id: "work",
        summary: "Event #{id}",
        all_day: false,
        start_at: ~U[2026-10-16 07:00:00Z],
        end_at: ~U[2026-10-16 08:00:00Z]
      },
      Map.new(attrs)
    )
  end

  test "the bulk answer is the one booking_copy?/1 gives event by event", %{events: events} do
    copies = EventDeletion.booking_copies(events)

    assert Enum.map(copies, & &1.id) == [1, 2]
    assert copies == Enum.filter(events, &EventDeletion.booking_copy?/1)
  end

  test "movable/2 keeps the editable events that are not copies", %{
    integration: integration,
    events: events
  } do
    assert Enum.map(EditGuard.movable([integration], events), & &1.id) == [3, 4, 5]

    assert Enum.filter(events, &EditGuard.movable?([integration], &1)) ==
             EditGuard.movable([integration], events)
  end

  test "a window's payload costs one meetings query whatever its size", %{
    integration: integration,
    events: events
  } do
    more = for id <- 10..29, do: event(integration, id, uid: "plain-#{id}")

    {payload, reads} =
      counting_meetings_reads(fn -> window_payload(integration, events ++ more) end)

    assert reads == 1

    assert payload.events |> Enum.reject(& &1.movable) |> Enum.map(& &1.id) ==
             ["event-1", "event-2"]
  end

  defp window_payload(integration, events) do
    EventPayload.build(%{
      view: :week,
      date: ~D[2026-10-16],
      window: Date.range(~D[2026-10-12], ~D[2026-10-18]),
      now: ~U[2026-10-16 06:00:00Z],
      timezone: "Etc/UTC",
      integration_tokens: %{},
      calendar_tokens: %{},
      integrations: [integration],
      events: events,
      settings: %{},
      reset: false
    })
  end

  defp counting_meetings_reads(fun) do
    parent = self()
    ref = make_ref()
    handler_id = "booking-copies-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source == "meetings", do: send(parent, {:meetings_read, ref})
      end,
      nil
    )

    try do
      result = fun.()
      {result, reads(ref)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp reads(ref, count \\ 0) do
    receive do
      {:meetings_read, ^ref} -> reads(ref, count + 1)
    after
      0 -> count
    end
  end
end
