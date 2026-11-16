defmodule Tymeslot.CalendarGrid.EventWindowTest do
  @moduledoc """
  Which events a span of days holds for an organiser: the cached events their
  calendar selection keeps, their bookings, less what they have hidden. The
  calendar surface loads through `EventWindow`, so this is the one place the
  rule is pinned.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.CalendarGrid.EventWindow

  defp google_account(user) do
    insert(:calendar_integration,
      user: user,
      provider: "google",
      is_active: true,
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true},
        %{"id" => "old", "name" => "Old", "selected" => false}
      ]
    )
  end

  defp cached(integration, calendar_id, summary, start_at, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          provider: "google",
          provider_calendar_id: calendar_id,
          summary: summary,
          start_at: start_at,
          end_at: DateTime.add(start_at, 60, :minute),
          all_day: false
        ],
        attrs
      )
    )
  end

  describe "list_events/5" do
    test "keeps selected calendars' events and adds bookings" do
      user = insert(:user)
      integration = google_account(user)
      cached(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
      cached(integration, "old", "Deselected calendar", ~U[2026-10-14 11:00:00Z])

      insert(:meeting,
        organizer_user: user,
        title: "Intro call",
        attendee_name: "Anna Kowalski",
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z],
        status: "confirmed"
      )

      events =
        EventWindow.list_events(
          user.id,
          [integration],
          ~U[2026-10-12 00:00:00Z],
          ~U[2026-10-19 00:00:00Z]
        )

      summaries = Enum.map(events, & &1.summary)

      assert "Design review" in summaries
      assert "Intro call" in summaries
      refute "Deselected calendar" in summaries
    end

    test "leaves out events outside the span" do
      user = insert(:user)
      integration = google_account(user)
      cached(integration, "work", "Next month", ~U[2026-11-20 09:00:00Z])

      assert EventWindow.list_events(
               user.id,
               [integration],
               ~U[2026-10-12 00:00:00Z],
               ~U[2026-10-19 00:00:00Z]
             ) == []
    end

    test "draws a booking in place of its calendar copy, naming the copy's calendar" do
      user = insert(:user)
      integration = google_account(user)

      cached(integration, "work", "Intro call with Anna Kowalski", ~U[2026-10-15 10:00:00Z],
        provider_event_id: "evt-intro"
      )

      cached(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])

      meeting =
        insert(:meeting,
          organizer_user: user,
          title: "Intro call with Anna Kowalski",
          meeting_type: "Intro call",
          attendee_name: "Anna Kowalski",
          start_time: ~U[2026-10-15 10:00:00Z],
          end_time: ~U[2026-10-15 10:30:00Z],
          status: "confirmed",
          provider_event_id: "evt-intro"
        )

      assert [%{summary: "Design review"}, %BookingEvent{} = booking] =
               EventWindow.list_events(
                 user.id,
                 [integration],
                 ~U[2026-10-12 00:00:00Z],
                 ~U[2026-10-19 00:00:00Z]
               )

      assert booking.meeting_id == meeting.id

      assert booking.copy == %{
               calendar_integration_id: integration.id,
               provider_calendar_id: "work",
               calendar_name: "Work"
             }
    end

    test "keeps a booking whose copy sits on a deselected calendar" do
      user = insert(:user)
      integration = google_account(user)

      cached(integration, "old", "Intro call", ~U[2026-10-15 10:00:00Z],
        provider_event_id: "evt-intro"
      )

      insert(:meeting,
        organizer_user: user,
        title: "Intro call",
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z],
        status: "confirmed",
        provider_event_id: "evt-intro"
      )

      assert [%BookingEvent{copy: %{calendar_name: "Old"}}] =
               EventWindow.list_events(
                 user.id,
                 [integration],
                 ~U[2026-10-12 00:00:00Z],
                 ~U[2026-10-19 00:00:00Z]
               )
    end

    test "drops every copy of a booking and names the visible copy's calendar" do
      user = insert(:user)
      integration = google_account(user)

      cached(integration, "old", "Intro call", ~U[2026-10-15 10:00:00Z],
        provider_event_id: "evt-intro",
        uid: "hidden-uid"
      )

      cached(integration, "work", "Intro call", ~U[2026-10-15 10:00:00Z],
        provider_event_id: "evt-intro-2",
        uid: "intro-uid"
      )

      insert(:meeting,
        organizer_user: user,
        title: "Intro call",
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z],
        status: "confirmed",
        provider_event_id: "evt-intro",
        calendar_uid: "intro-uid"
      )

      assert [%BookingEvent{copy: %{calendar_name: "Work"}}] =
               EventWindow.list_events(
                 user.id,
                 [integration],
                 ~U[2026-10-12 00:00:00Z],
                 ~U[2026-10-19 00:00:00Z]
               )
    end

    test "a booking with no copy has none, and expired requests come only when asked" do
      user = insert(:user)
      integration = google_account(user)

      insert(:meeting,
        organizer_user: user,
        title: "Lapsed request",
        start_time: ~U[2026-10-16 10:00:00Z],
        end_time: ~U[2026-10-16 10:30:00Z],
        status: "expired",
        approval_requested_at: ~U[2026-10-13 10:00:00Z],
        approval_resolved_at: ~U[2026-10-14 07:00:00Z],
        cancelled_at: ~U[2026-10-14 07:00:00Z]
      )

      range = [user.id, [integration], ~U[2026-10-12 00:00:00Z], ~U[2026-10-19 00:00:00Z]]

      assert apply(EventWindow, :list_events, range) == []

      assert [%BookingEvent{summary: "Lapsed request", expired: true, copy: nil}] =
               apply(EventWindow, :list_events, range ++ [[include_expired: true]])
    end
  end

  describe "reject_hidden/3" do
    @work %{calendar_integration_id: 1, provider_calendar_id: "work", summary: "Work"}
    @family %{calendar_integration_id: 1, provider_calendar_id: "family", summary: "Family"}
    @other %{calendar_integration_id: 2, provider_calendar_id: "primary", summary: "Other"}
    @booking %{kind: :booking, calendar_integration_id: nil, summary: "Booking"}

    test "hides one calendar by its key" do
      assert EventWindow.reject_hidden(
               [@work, @family, @booking],
               [],
               MapSet.new([{1, "family"}])
             ) ==
               [@work, @booking]
    end

    test "hides a whole account by its id" do
      assert EventWindow.reject_hidden([@work, @family, @other], [1], MapSet.new()) == [@other]
    end

    test "never hides a booking, which belongs to no calendar" do
      assert EventWindow.reject_hidden([@booking], [1, 2], MapSet.new([{1, "work"}])) == [
               @booking
             ]
    end
  end

  describe "utc_range/3" do
    test "runs from local midnight of the first day to midnight after the last" do
      assert EventWindow.utc_range(~D[2027-02-22], ~D[2027-02-28], "Asia/Tokyo") ==
               {~U[2027-02-21 15:00:00Z], ~U[2027-02-28 15:00:00Z]}
    end

    test "starts a day with no midnight at its first instant" do
      # Chile moves its clocks forward at 24:00 on the first Saturday of
      # September, so 6 September 2026 starts at 01:00.
      assert {~U[2026-09-06 04:00:00Z], _end} =
               EventWindow.utc_range(~D[2026-09-06], ~D[2026-09-06], "America/Santiago")
    end

    test "ends on the new offset's midnight across a DST change" do
      assert EventWindow.utc_range(~D[2026-10-31], ~D[2026-11-02], "America/New_York") ==
               {~U[2026-10-31 04:00:00Z], ~U[2026-11-03 05:00:00Z]}
    end
  end
end
