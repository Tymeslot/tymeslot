defmodule Tymeslot.CalendarGrid.EventSearchTest do
  @moduledoc """
  `CalendarGrid.search_calendar/5`, the calendar's search: nearest to
  now first, a repeating event once, hidden calendars and calendars outside
  the active set left out, bookings found by their guest and in place of
  their calendar copies, and the typed term matched literally.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.CalendarGrid.EffectiveVisibility

  @now ~U[2026-10-14 08:00:00Z]

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true},
          %{"id" => "family", "name" => "Family", "selected" => true}
        ]
      )

    %{user: user, integration: integration}
  end

  defp event(integration, summary, start_at, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          provider: "google",
          provider_calendar_id: "work",
          summary: summary,
          start_at: start_at,
          end_at: DateTime.add(start_at, 60, :minute),
          all_day: false
        ],
        attrs
      )
    )
  end

  defp booking(user, attrs) do
    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: user.id,
          start_time: ~U[2026-10-16 13:00:00Z],
          end_time: ~U[2026-10-16 14:00:00Z]
        ],
        attrs
      )
    )
  end

  defp everything_shown(integration),
    do: EffectiveVisibility.resolve([], MapSet.new(), [integration], nil)

  defp search(user, integration, term, visibility \\ nil, opts \\ []) do
    CalendarGrid.search_calendar(
      user.id,
      term,
      [integration],
      visibility || everything_shown(integration),
      Keyword.put(opts, :now, @now)
    )
  end

  defp titles(hits), do: Enum.map(hits, & &1.title)

  test "a term under two characters searches nothing", %{user: user, integration: integration} do
    event(integration, "Design review", ~U[2026-10-15 09:00:00Z])

    assert search(user, integration, "d") == %{events: [], bookings: []}
    assert search(user, integration, "  d  ") == %{events: [], bookings: []}
  end

  test "events come nearest first: upcoming ascending, then past latest first", %{
    user: user,
    integration: integration
  } do
    for {summary, days} <- [
          {"Standup A", -2},
          {"Standup B", -1},
          {"Standup C", 1},
          {"Standup D", 3}
        ] do
      event(integration, summary, DateTime.add(@now, days, :day))
    end

    assert titles(search(user, integration, "standup").events) ==
             ["Standup C", "Standup D", "Standup B", "Standup A"]
  end

  test "an event hit carries what the reveal needs", %{user: user, integration: integration} do
    row = event(integration, "Design review", ~U[2026-10-15 09:00:00Z])

    assert [hit] = search(user, integration, "design").events
    assert hit.id == "event-#{row.id}"
    assert hit.ids == [hit.id]
    assert hit.kind == :event
    assert hit.all_day == false
    assert hit.series == false
    assert hit.calendar_integration_id == integration.id
    assert hit.provider_calendar_id == "work"
    assert DateTime.compare(hit.start, ~U[2026-10-15 09:00:00Z]) == :eq
  end

  test "a weekly series appears once, at its next occurrence", %{
    user: user,
    integration: integration
  } do
    for days <- [-7, 7, 14] do
      event(integration, "Team sync", DateTime.add(@now, days, :day),
        recurring_event_id: "weekly-sync",
        provider_event_id: "weekly-sync_#{days}"
      )
    end

    assert [%{title: "Team sync", series: true, start: start}] =
             search(user, integration, "team sync").events

    assert DateTime.compare(start, DateTime.add(@now, 7, :day)) == :eq
  end

  test "a series that has ended appears once, at its latest occurrence", %{
    user: user,
    integration: integration
  } do
    for days <- [-14, -7] do
      event(integration, "Old sync", DateTime.add(@now, days, :day),
        recurring_event_id: "old-sync",
        provider_event_id: "old-sync_#{days}"
      )
    end

    assert [%{start: start}] = search(user, integration, "old sync").events
    assert DateTime.compare(start, DateTime.add(@now, -7, :day)) == :eq
  end

  test "a hidden calendar's events are left out", %{user: user, integration: integration} do
    event(integration, "Design review", ~U[2026-10-15 09:00:00Z])
    event(integration, "Family review", ~U[2026-10-15 10:00:00Z], provider_calendar_id: "family")

    visibility =
      EffectiveVisibility.resolve(
        [],
        MapSet.new([{integration.id, "family"}]),
        [integration],
        nil
      )

    assert titles(search(user, integration, "review", visibility).events) == ["Design review"]
  end

  test "a hidden account's events are left out", %{user: user, integration: integration} do
    event(integration, "Design review", ~U[2026-10-15 09:00:00Z])
    visibility = EffectiveVisibility.resolve([integration.id], MapSet.new(), [integration], nil)

    assert search(user, integration, "review", visibility).events == []
  end

  test "while a set is active, calendars outside it are left out", %{
    user: user,
    integration: integration
  } do
    event(integration, "Design review", ~U[2026-10-15 09:00:00Z])
    event(integration, "Family review", ~U[2026-10-15 10:00:00Z], provider_calendar_id: "family")

    {:ok, _set} =
      CalendarSets.create(user.id, "Work", [
        %{integration_id: integration.id, calendar_id: "work"}
      ])

    {:ok, _active} = CalendarSets.activate(user.id, 1)

    visibility = EffectiveVisibility.for_user(user.id)
    assert titles(search(user, integration, "review", visibility).events) == ["Design review"]
  end

  test "while a set is active, an account outside it is left out", %{
    user: user,
    integration: integration
  } do
    other =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        calendar_list: [%{"id" => "work", "name" => "Work", "selected" => true}]
      )

    event(integration, "Design review", ~U[2026-10-15 09:00:00Z])
    event(other, "Other review", ~U[2026-10-15 10:00:00Z])

    {:ok, _set} =
      CalendarSets.create(user.id, "Work", [
        %{integration_id: integration.id, calendar_id: "work"}
      ])

    {:ok, _active} = CalendarSets.activate(user.id, 1)

    result =
      CalendarGrid.search_calendar(
        user.id,
        "review",
        [integration, other],
        EffectiveVisibility.for_user(user.id),
        now: @now
      )

    assert titles(result.events) == ["Design review"]
  end

  test "a daily series does not crowd out other matches", %{user: user, integration: integration} do
    for days <- 1..30 do
      event(integration, "Daily sync", DateTime.add(@now, days, :day),
        recurring_event_id: "daily-sync",
        provider_event_id: "daily-sync_#{days}"
      )
    end

    event(integration, "Quarterly sync", DateTime.add(@now, 35, :day))

    result = search(user, integration, "sync").events

    assert titles(result) == ["Daily sync", "Quarterly sync"]
    assert [%{series: true, start: start}, _quarterly] = result
    assert DateTime.compare(start, DateTime.add(@now, 1, :day)) == :eq
  end

  test "a daily series that has ended does not crowd out other past matches", %{
    user: user,
    integration: integration
  } do
    for days <- 1..30 do
      event(integration, "Daily sync", DateTime.add(@now, -days, :day),
        recurring_event_id: "daily-sync",
        provider_event_id: "daily-sync_#{days}"
      )
    end

    event(integration, "Quarterly sync", DateTime.add(@now, -35, :day))

    assert titles(search(user, integration, "sync").events) == ["Daily sync", "Quarterly sync"]
  end

  test "a booking is found by its guest's name and email", %{
    user: user,
    integration: integration
  } do
    meeting =
      booking(user,
        title: "Intro call",
        meeting_type: "Intro call",
        attendee_name: "Anna Novak",
        attendee_email: "anna@novak.example"
      )

    for term <- ["novak", "anna@nov"] do
      assert [%{id: id, ids: [id], kind: :booking, title: "Anna Novak · Intro call"} = hit] =
               search(user, integration, term).bookings

      assert id == "booking-#{meeting.id}"
      assert hit.meeting_type == "Intro call"
    end
  end

  test "a cancelled booking and another organiser's booking are not found", %{
    user: user,
    integration: integration
  } do
    live = booking(user, attendee_name: "Cara Lind")
    booking(user, attendee_name: "Cara Lind", status: "cancelled")
    booking(insert(:user), attendee_name: "Cara Lind")

    assert [%{id: id}] = search(user, integration, "lind").bookings
    assert id == "booking-#{live.id}"
  end

  test "a request that expired unanswered is found, as the grid draws it", %{
    user: user,
    integration: integration
  } do
    expired =
      booking(user,
        attendee_name: "Dan Request",
        status: "expired",
        approval_requested_at: ~U[2026-10-10 09:00:00Z],
        approval_resolved_at: ~U[2026-10-11 09:00:00Z],
        cancelled_at: ~U[2026-10-11 09:00:00Z]
      )

    assert [%{id: id}] = search(user, integration, "dan request").bookings
    assert id == "booking-#{expired.id}"
  end

  test "a hit on a booking's calendar copy is the booking", %{
    user: user,
    integration: integration
  } do
    meeting =
      booking(user,
        title: "Intro call",
        meeting_type: "Intro call",
        attendee_name: "Bob Ray",
        calendar_integration_id: integration.id,
        provider_event_id: "google-evt-1"
      )

    event(integration, "Quarterly planning with Bob", ~U[2026-10-16 13:00:00Z],
      provider_event_id: "google-evt-1"
    )

    result = search(user, integration, "quarterly")

    assert result.events == []
    assert [%{id: id, kind: :booking, title: "Bob Ray · Intro call"}] = result.bookings
    assert id == "booking-#{meeting.id}"
  end

  test "a booking found by its own fields and by its copy is listed once", %{
    user: user,
    integration: integration
  } do
    booking(user,
      attendee_name: "Bob Ray",
      calendar_integration_id: integration.id,
      provider_event_id: "google-evt-2"
    )

    event(integration, "Planning with Bob", ~U[2026-10-16 13:00:00Z],
      provider_event_id: "google-evt-2"
    )

    result = search(user, integration, "bob")

    assert result.events == []
    assert length(result.bookings) == 1
  end

  test "the copy of a cancelled booking stays an event, as the grid draws it", %{
    user: user,
    integration: integration
  } do
    booking(user,
      status: "cancelled",
      calendar_integration_id: integration.id,
      provider_event_id: "google-evt-3"
    )

    row =
      event(integration, "Cancelled intro", ~U[2026-10-16 13:00:00Z],
        provider_event_id: "google-evt-3"
      )

    assert [%{id: id, kind: :event}] = search(user, integration, "cancelled intro").events
    assert id == "event-#{row.id}"
  end

  test "a booking's LIKE metacharacters match literally", %{user: user, integration: integration} do
    kept = booking(user, attendee_name: "a_b Guest")

    booking(user,
      attendee_name: "axb Guest",
      start_time: ~U[2026-10-17 13:00:00Z],
      end_time: ~U[2026-10-17 14:00:00Z]
    )

    assert [%{id: id}] = search(user, integration, "a_b").bookings
    assert id == "booking-#{kept.id}"
  end

  test "a backslash in the term matches literally and a trailing one does not error", %{
    user: user,
    integration: integration
  } do
    row = event(integration, "Share C:\\x drive", ~U[2026-10-15 09:00:00Z])
    event(integration, "Share C:x drive", ~U[2026-10-15 10:00:00Z])
    meeting = booking(user, attendee_name: "Eve C:\\x")

    booking(user,
      attendee_name: "Eve C:x",
      start_time: ~U[2026-10-17 13:00:00Z],
      end_time: ~U[2026-10-17 14:00:00Z]
    )

    result = search(user, integration, "c:\\x")

    assert [%{id: event_id}] = result.events
    assert event_id == "event-#{row.id}"
    assert [%{id: booking_id}] = result.bookings
    assert booking_id == "booking-#{meeting.id}"

    assert %{events: [], bookings: []} = search(user, integration, "drive\\")
  end

  test "a long term is cut to 100 characters", %{user: user, integration: integration} do
    event(integration, String.duplicate("a", 100), ~U[2026-10-15 09:00:00Z])

    assert [_hit] = search(user, integration, String.duplicate("a", 150)).events
  end

  test "a copy of a booking awaiting payment is the booking", %{
    user: user,
    integration: integration
  } do
    meeting =
      booking(user,
        attendee_name: "Pay Later",
        status: "awaiting_payment",
        calendar_integration_id: integration.id,
        provider_event_id: "google-evt-4"
      )

    event(integration, "Paid intro", ~U[2026-10-16 13:00:00Z], provider_event_id: "google-evt-4")

    result = search(user, integration, "paid intro")

    assert result.events == []
    assert [%{id: id}] = result.bookings
    assert id == "booking-#{meeting.id}"
  end

  test "a cancelled booking sharing an identifier does not take a live booking's place", %{
    user: user,
    integration: integration
  } do
    live =
      booking(user,
        attendee_name: "Live Guest",
        calendar_integration_id: integration.id,
        provider_event_id: "google-evt-5"
      )

    booking(user,
      attendee_name: "Gone Guest",
      status: "cancelled",
      calendar_integration_id: integration.id,
      provider_event_id: "google-evt-5"
    )

    event(integration, "Shared slot", ~U[2026-10-16 13:00:00Z], provider_event_id: "google-evt-5")

    result = search(user, integration, "shared slot")

    assert result.events == []
    assert [%{id: id}] = result.bookings
    assert id == "booking-#{live.id}"
  end

  test "LIKE metacharacters in the term match literally", %{user: user, integration: integration} do
    event(integration, "100% sure", ~U[2026-10-15 09:00:00Z])
    event(integration, "1000 sure", ~U[2026-10-15 10:00:00Z])
    event(integration, "a_b plan", ~U[2026-10-15 11:00:00Z])
    event(integration, "axb plan", ~U[2026-10-15 12:00:00Z])

    assert titles(search(user, integration, "0% s").events) == ["100% sure"]
    assert titles(search(user, integration, "a_b").events) == ["a_b plan"]
  end

  test "at most eight events by default, or the limit asked for", %{
    user: user,
    integration: integration
  } do
    for hours <- 1..10,
        do: event(integration, "Focus block #{hours}", DateTime.add(@now, hours, :hour))

    assert length(search(user, integration, "focus block").events) == 8

    assert length(search(user, integration, "focus block", nil, limit: %{events: 3}).events) ==
             3
  end
end
