defmodule Tymeslot.CalendarGrid.EventWindowTest do
  @moduledoc """
  Which events a span of days holds for an organiser: the cached events their
  calendar selection keeps, their bookings, less what they have hidden. Both
  calendar surfaces load through `EventWindow`, so this is the one place the
  rule is pinned.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

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

  defp cached(integration, calendar_id, summary, start_at) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      provider_calendar_id: calendar_id,
      summary: summary,
      start_at: start_at,
      end_at: DateTime.add(start_at, 60, :minute),
      all_day: false
    )
  end

  describe "list_events/4" do
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
  end
end
