defmodule Tymeslot.CalendarGrid.EventPayloadTest do
  @moduledoc """
  The JSON the `CalendarCanvas` hook draws the grid from. Times must be the
  organiser's wall clock, never instants, because the browser may sit in
  another zone than the one the booking engine reads the organiser in.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  @context %{
    timezone: "Europe/Warsaw",
    integration_tokens: %{7 => "calendar-3"},
    calendar_tokens: %{}
  }

  defp timed(attrs) do
    struct!(
      %ProviderCalendarEventSchema{
        id: 42,
        calendar_integration_id: 7,
        provider_calendar_id: "work",
        summary: "Design review",
        all_day: false,
        start_at: ~U[2026-10-16 07:30:00.000000Z],
        end_at: ~U[2026-10-16 08:15:00.000000Z],
        transparency: "opaque",
        sync_state: "synced"
      },
      attrs
    )
  end

  defp booking(attrs) do
    struct!(
      %BookingEvent{
        id: "booking-abc",
        meeting_id: "abc",
        summary: "Intro call",
        start_at: ~U[2026-10-16 12:00:00Z],
        end_at: ~U[2026-10-16 12:30:00Z],
        attendee_name: "Anna Kowalski"
      },
      attrs
    )
  end

  test "a timed event carries wall-clock times in the organiser's zone" do
    assert EventPayload.event(timed([]), @context) == %{
             id: "event-42",
             kind: "event",
             title: "Design review",
             all_day: false,
             start: "2026-10-16T09:30",
             end: "2026-10-16T10:15",
             colour: "calendar-3",
             free: false,
             attention: false,
             editable: false,
             movable: false
           }
  end

  test "an event inside the hour the clocks go back keeps its length" do
    payload =
      EventPayload.event(
        timed(start_at: ~U[2026-10-25 00:30:00Z], end_at: ~U[2026-10-25 01:15:00Z]),
        @context
      )

    assert {payload.start, payload.end} == {"2026-10-25T02:30", "2026-10-25T03:15"}
  end

  test "an event shorter than a minute still lasts a minute on the grid" do
    payload =
      EventPayload.event(
        timed(start_at: ~U[2026-10-16 07:30:10Z], end_at: ~U[2026-10-16 07:30:40Z]),
        @context
      )

    assert {payload.start, payload.end} == {"2026-10-16T09:30", "2026-10-16T09:31"}
  end

  test "an all-day event carries its dates with the exclusive end it is stored with" do
    event =
      timed(
        all_day: true,
        start_at: nil,
        end_at: nil,
        start_date: ~D[2026-10-16],
        end_date: ~D[2026-10-18]
      )

    assert %{all_day: true, start: "2026-10-16", end: "2026-10-18"} =
             EventPayload.event(event, @context)
  end

  test "an all-day event with no usable end lasts one day" do
    event =
      timed(all_day: true, start_at: nil, end_at: nil, start_date: ~D[2026-10-16], end_date: nil)

    assert %{start: "2026-10-16", end: "2026-10-17"} = EventPayload.event(event, @context)
  end

  test "a booking leads with the guest's name and has its own kind and colour" do
    assert %{
             id: "booking-abc",
             kind: "booking",
             title: "Anna Kowalski · Intro call",
             colour: "booking"
           } =
             EventPayload.event(booking([]), @context)
  end

  test "a group booking keeps its own title, having no single guest" do
    event = booking(participants: [%{name: "Ada", email: "ada@example.com"}])

    assert %{title: "Intro call"} = EventPayload.event(event, @context)
  end

  test "an untitled event says so" do
    assert %{title: "(No title)"} = EventPayload.event(timed(summary: "   "), @context)
    assert %{title: "(No title)"} = EventPayload.event(timed(summary: nil), @context)
  end

  test "a transparent event is free and an unsynced one needs attention" do
    assert %{free: true} = EventPayload.event(timed(transparency: "transparent"), @context)

    assert %{attention: true} =
             EventPayload.event(timed(sync_state: "locally_modified"), @context)
  end

  test "build/1 wraps the events with the period, the loaded range and the organiser's now" do
    payload =
      EventPayload.build(%{
        view: :three_day,
        date: ~D[2026-10-16],
        window: Date.range(~D[2026-10-13], ~D[2026-10-21]),
        now: ~U[2026-10-16 22:30:00Z],
        timezone: "Europe/Warsaw",
        integration_tokens: %{},
        calendar_tokens: %{},
        events: [timed([])],
        settings: %{density: "compact"},
        reset: true
      })

    assert payload.view == "three_day"
    assert payload.date == "2026-10-16"
    assert payload.range == %{from: "2026-10-13", to: "2026-10-22"}
    assert payload.now == "2026-10-17T00:30"
    assert payload.reset == true
    assert payload.settings == %{density: "compact"}
    assert [%{id: "event-42"}] = payload.events
  end

  describe "editable" do
    # As loaded from the database, where the list is cast to entries.
    defp integration(calendar_list),
      do: %CalendarIntegrationSchema{
        id: 7,
        provider: "google",
        calendar_list: Enum.map(calendar_list, &CalendarEntry.normalize/1)
      }

    test "an event on a writable calendar of the organiser's can be changed" do
      context =
        Map.put(@context, :integrations, [integration([%{"id" => "work", "selected" => true}])])

      assert %{editable: true} = EventPayload.event(timed([]), context)
    end

    test "an event on a read-only calendar cannot" do
      list = [%{"id" => "work", "selected" => true, "read_only" => true}]
      context = Map.put(@context, :integrations, [integration(list)])

      assert %{editable: false} = EventPayload.event(timed([]), context)
    end

    test "without the organiser's integrations nothing is offered" do
      assert %{editable: false} = EventPayload.event(timed([]), @context)
    end
  end
end
