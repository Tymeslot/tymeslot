defmodule Tymeslot.Availability.CalendarBlockingOfferTest do
  @moduledoc """
  The booking page and the booking submit against a Google account whose
  calendars the host set to block or to show only, read through the real
  availability path down to the provider API.

  A calendar set to show only is never read for availability, so its events
  cannot take a slot and its failures cannot refuse one. A blocking calendar,
  read-only or not, takes slots, and one that cannot be read refuses them.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.CalendarCheck
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.Runtime.EventFetcher
  alias Tymeslot.TestMocks

  @moduletag :capture_log

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    stub(CalendarMock, :get_events_for_range_fresh, &EventFetcher.get_events_for_range_fresh/3)

    %{user: user, profile: profile} = create_bookable_profile(timezone: "Etc/UTC")
    %{user: user, profile: profile, date: next_bookable_weekday()}
  end

  # Each calendar answers with one 30-minute event at its own time, so which
  # slots disappear says which calendars were read.
  @busy_at %{"work" => ~T[11:00:00], "holidays" => ~T[14:00:00], "rota" => ~T[15:00:00]}

  defp stub_google(date, opts \\ []) do
    test_pid = self()
    failing = Keyword.get(opts, :failing, [])

    stub(GoogleCalendarAPIMock, :list_events, fn _integration, calendar_id, _from, _to ->
      send(test_pid, {:read, calendar_id})

      if calendar_id in failing,
        do: {:error, :network_error, "unreachable"},
        else: {:ok, [google_event(calendar_id, date, Map.fetch!(@busy_at, calendar_id))]}
    end)

    stub(GoogleCalendarAPIMock, :list_primary_events, fn _integration, _from, _to ->
      send(test_pid, {:read, "primary"})
      {:ok, [google_event("primary", date, ~T[12:00:00])]}
    end)
  end

  defp google_event(calendar_id, date, time) do
    start = DateTime.new!(date, time, "Etc/UTC")

    %{
      "id" => "#{calendar_id}-event",
      "summary" => "#{calendar_id} event",
      "status" => "confirmed",
      "start" => %{"dateTime" => DateTime.to_iso8601(start)},
      "end" => %{"dateTime" => start |> DateTime.add(30, :minute) |> DateTime.to_iso8601()}
    }
  end

  defp google_integration(user, calendar_list) do
    insert(:calendar_integration,
      user: user,
      provider: "google",
      is_active: true,
      oauth_scope: "https://www.googleapis.com/auth/calendar",
      calendar_list: calendar_list
    )
  end

  defp probe(user, date, time) do
    start = DateTime.new!(date, time, "Etc/UTC")

    CalendarCheck.probe(
      %{
        organizer_user_id: user.id,
        start_datetime: start,
        end_datetime: DateTime.add(start, 30, :minute)
      },
      %{buffer_before_minutes: 0, buffer_after_minutes: 0}
    )
  end

  describe "a calendar set to show only" do
    setup %{user: user, date: date} do
      stub_google(date)

      integration =
        google_integration(user, [
          %{id: "work", name: "Work", selected: true, primary: true},
          %{id: "holidays", name: "Holidays", selected: true, blocks_availability: false}
        ])

      %{integration: integration}
    end

    test "leaves its times bookable while the blocking calendar takes its own", %{
      user: user,
      profile: profile,
      date: date
    } do
      slots = offered(profile, date, "30min")

      assert "2:00 PM" in slots
      refute "11:00 AM" in slots
      refute_received {:read, "holidays"}

      assert :ok = probe(user, date, ~T[14:00:00])
      assert {:error, :slot_unavailable} = probe(user, date, ~T[11:00:00])
    end

    test "still shows its events on the grid", %{user: user, integration: integration} do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_calendar_id: "holidays",
        summary: "Bank holiday"
      )

      assert [%{summary: "Bank holiday"}] =
               CalendarGrid.search_events(user.id, "Bank holiday", [integration])
    end
  end

  test "a read-only calendar shared with the host blocks like any other", %{
    user: user,
    profile: profile,
    date: date
  } do
    stub_google(date)

    google_integration(user, [
      %{id: "work", selected: true, primary: true},
      %{id: "rota", selected: true, read_only: true, access_role: "reader"}
    ])

    slots = offered(profile, date, "30min")

    refute "3:00 PM" in slots
    assert "2:00 PM" in slots
    assert {:error, :slot_unavailable} = probe(user, date, ~T[15:00:00])
  end

  describe "a calendar that cannot be read" do
    test "refuses every slot when it blocks", %{user: user, profile: profile, date: date} do
      stub_google(date, failing: ["holidays"])

      google_integration(user, [
        %{id: "work", selected: true, primary: true},
        %{id: "holidays", selected: true}
      ])

      assert {:error, _reason} =
               Offer.slots_for_date(
                 %{profile: profile, user_timezone: "Etc/UTC", meeting_type: nil},
                 Date.to_iso8601(date),
                 "30min"
               )

      assert {:error, :some_calendars_unavailable} = probe(user, date, ~T[14:00:00])
    end

    test "refuses nothing when it shows only", %{user: user, profile: profile, date: date} do
      stub_google(date, failing: ["holidays"])

      google_integration(user, [
        %{id: "work", selected: true, primary: true},
        %{id: "holidays", selected: true, blocks_availability: false}
      ])

      assert "2:00 PM" in offered(profile, date, "30min")
      assert :ok = probe(user, date, ~T[14:00:00])
    end
  end

  test "an account whose calendars all show only is not read at all, primary included", %{
    user: user,
    profile: profile,
    date: date
  } do
    stub_google(date)

    google_integration(user, [
      %{id: "work", selected: true, primary: true, blocks_availability: false}
    ])

    slots = offered(profile, date, "30min")

    assert "11:00 AM" in slots
    assert "12:00 PM" in slots
    refute_received {:read, _calendar}
    assert :ok = probe(user, date, ~T[11:00:00])
  end

  test "an account whose owner unticked every calendar still blocks through its primary", %{
    user: user,
    profile: profile,
    date: date
  } do
    stub_google(date)
    google_integration(user, [%{id: "work", selected: false, primary: true}])

    refute "12:00 PM" in offered(profile, date, "30min")
    assert_received {:read, "primary"}
    assert {:error, :slot_unavailable} = probe(user, date, ~T[12:00:00])
  end

  test "an account connected before calendar selection still blocks through its primary", %{
    user: user,
    profile: profile,
    date: date
  } do
    stub_google(date)
    google_integration(user, [])

    slots = offered(profile, date, "30min")

    refute "12:00 PM" in slots
    assert "11:00 AM" in slots
    assert_received {:read, "primary"}
    assert {:error, :slot_unavailable} = probe(user, date, ~T[12:00:00])
  end
end
