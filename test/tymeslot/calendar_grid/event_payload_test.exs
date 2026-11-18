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
  alias Tymeslot.CalendarGrid.CreateParams
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
        summary: "Intro call with Anna Kowalski",
        meeting_type: "Intro call",
        start_at: ~U[2026-10-16 12:00:00Z],
        end_at: ~U[2026-10-16 12:30:00Z],
        attendee_name: "Anna Kowalski"
      },
      attrs
    )
  end

  defp draft_params(attrs) do
    struct!(
      %CreateParams{
        integration_id: 7,
        calendar_id: "work",
        title: "Lunch",
        start_at: ~U[2026-10-16 11:00:00Z],
        end_at: ~U[2026-10-16 12:00:00Z],
        timezone: "Europe/Warsaw"
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
             movable: false,
             locked: false,
             preview: false,
             calendar: "7:work",
             recurring: false,
             guests: 0,
             replies: nil,
             request: false,
             expired: false,
             tymeslot: false
           }
  end

  test "an event created in Tymeslot says so, for the agenda's Bookings filter" do
    assert %{tymeslot: true} = EventPayload.event(timed(created_by_tymeslot: true), @context)
    assert %{tymeslot: false} = EventPayload.event(timed(created_by_tymeslot: false), @context)
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
    event = booking(participants: [%{name: "Ada", email: "ada@example.com"}], summary: "Workshop")

    assert %{title: "Workshop"} = EventPayload.event(event, @context)
  end

  test "a booking missing its meeting type leads with its guest, then its own title" do
    assert %{title: "Anna Kowalski · Coffee chat"} =
             EventPayload.event(booking(meeting_type: nil, summary: "Coffee chat"), @context)
  end

  test "a booking missing its guest's name keeps its own title" do
    assert %{title: "Intro call with Anna Kowalski"} =
             EventPayload.event(booking(attendee_name: nil), @context)
  end

  test "a booking says whether it is a request and whether it expired; an event is neither" do
    assert %{request: false, expired: false} = EventPayload.event(booking([]), @context)
    assert %{request: true, expired: false} = EventPayload.event(booking(request: true), @context)

    assert %{request: true, expired: true} =
             EventPayload.event(booking(request: true, expired: true), @context)

    assert %{request: false, expired: false} = EventPayload.event(timed([]), @context)
  end

  test "an expired request counts as free time, a live one does not" do
    assert %{free: true} = EventPayload.event(booking(request: true, expired: true), @context)
    assert %{free: false} = EventPayload.event(booking(request: true), @context)
    assert %{free: false} = EventPayload.event(booking([]), @context)
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
        drafts: [{"d1", draft_params([]), true}],
        settings: %{density: "compact"},
        reset: true
      })

    assert payload.view == "three_day"
    assert payload.date == "2026-10-16"
    assert payload.range == %{from: "2026-10-13", to: "2026-10-22"}
    assert payload.now == "2026-10-17T00:30"
    assert payload.reset == true
    assert payload.settings == %{density: "compact"}
    assert [%{id: "event-42"}, %{id: "draft-d1", kind: "draft"}] = payload.events
  end

  describe "calendar, repeats and guests" do
    test "a booking has no calendar of its own" do
      assert %{calendar: nil} = EventPayload.event(booking([]), @context)
    end

    test "an event without a calendar id has no key" do
      assert %{calendar: nil} = EventPayload.event(timed(provider_calendar_id: nil), @context)
    end

    test "a series master or occurrence repeats" do
      assert %{recurring: true} =
               EventPayload.event(timed(recurrence_rule: "FREQ=WEEKLY"), @context)

      assert %{recurring: true} = EventPayload.event(timed(recurring_event_id: "m-1"), @context)
      assert %{recurring: false} = EventPayload.event(booking([]), @context)
    end

    test "counts the guests with an address" do
      attendees = [%{"email" => "anna@example.com"}, %{"email" => "ben@example.com"}, %{}]

      assert %{guests: 2} = EventPayload.event(timed(attendees: attendees), @context)
    end

    test "a booking's guests are its guest, or each participant of a group" do
      assert %{guests: 1} = EventPayload.event(booking([]), @context)

      group =
        booking(
          participants: [
            %{name: "Ada", email: "ada@example.com"},
            %{name: "Bo", email: "bo@example.com"}
          ]
        )

      assert %{guests: 2} = EventPayload.event(group, @context)
    end

    test "a booking's invited guests count beside the person who booked" do
      invited = [
        %{name: nil, email: "grace@example.com", status: "pending"},
        %{name: "Alan", email: "alan@example.com", status: "declined"}
      ]

      assert %{guests: 3} = EventPayload.event(booking(guests: invited), @context)
    end
  end

  describe "replies" do
    @attendees [
      %{"email" => "ada@example.com", "response_status" => "accepted"},
      %{"email" => "grace@example.com", "response_status" => "declined"},
      %{"email" => "alan@example.com", "response_status" => "needs_action"},
      %{"email" => "linus@example.com"}
    ]

    test "an event Tymeslot made counts its guests' answers, leaving out those with none" do
      assert %{
               replies: %{
                 accepted: 1,
                 declined: 1,
                 total: 3,
                 label: "1 of 3 guests going, 1 declined"
               }
             } =
               EventPayload.event(
                 timed(created_by_tymeslot: true, attendees: @attendees),
                 @context
               )
    end

    test "another event's attendees are not counted" do
      assert %{replies: nil} = EventPayload.event(timed(attendees: @attendees), @context)
    end

    test "a booking counts its invited guests, never the person who booked" do
      invited = [
        %{name: nil, email: "grace@example.com", status: :accepted},
        %{name: "Alan", email: "alan@example.com", status: :pending}
      ]

      assert %{replies: %{accepted: 1, declined: 0, total: 2, label: "1 of 2 guests going"}} =
               EventPayload.event(booking(guests: invited), @context)

      assert %{replies: nil} = EventPayload.event(booking([]), @context)
    end
  end

  describe "draft/4" do
    test "a pending create is drawn as a saving draft in the organiser's wall clock" do
      assert EventPayload.draft("d1", draft_params([]), true, @context) == %{
               id: "draft-d1",
               kind: "draft",
               title: "Lunch",
               all_day: false,
               start: "2026-10-16T13:00",
               end: "2026-10-16T14:00",
               colour: "calendar-3",
               free: false,
               attention: false,
               editable: false,
               movable: false,
               locked: false,
               pending: true,
               calendar: "7:work",
               recurring: false,
               guests: 0,
               replies: nil
             }
    end

    test "the panel's draft is not saving, and says what it will be" do
      params =
        draft_params(
          free: true,
          guests: ["anna@example.com"],
          recurrence_rule: "FREQ=WEEKLY"
        )

      assert %{pending: false, free: true, guests: 1, recurring: true} =
               EventPayload.draft("panel", params, false, @context)
    end

    test "an all-day draft carries its dates with the exclusive end" do
      params = draft_params(all_day: true, start_at: ~D[2026-10-16], end_at: ~D[2026-10-18])

      assert %{all_day: true, start: "2026-10-16", end: "2026-10-18"} =
               EventPayload.draft("d2", params, true, @context)
    end
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

    test "an event a group meeting with live seats sits on is locked, and cannot be changed" do
      context =
        Map.merge(@context, %{
          integrations: [integration([%{"id" => "work", "selected" => true}])],
          locked_uids: MapSet.new(["seats-1"])
        })

      assert %{locked: true, editable: false, movable: false} =
               EventPayload.event(timed(uid: "seats-1"), context)
    end

    test "without the organiser's integrations nothing is offered" do
      assert %{editable: false} = EventPayload.event(timed([]), @context)
    end
  end
end
