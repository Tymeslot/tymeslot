defmodule Tymeslot.CalendarGrid.BlockTimeTest do
  @moduledoc """
  `Changes.block_time/4`: a stretch guests can no longer book. On the
  organiser's default writable calendar that blocks availability it is a
  busy event; with no such calendar it is time off, which the booking page
  honours. `Changes.unblock_time/2` takes either back.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    host = create_bookable_profile()
    date = next_bookable_weekday()

    Map.merge(host, %{
      date: date,
      start_at: DateTime.new!(date, ~T[13:00:00], "Etc/UTC"),
      end_at: DateTime.new!(date, ~T[14:00:00], "Etc/UTC")
    })
  end

  defp google(host, calendar_list) do
    insert(:calendar_integration,
      user: host.user,
      provider: "google",
      is_active: true,
      calendar_list: calendar_list
    )
  end

  defp expect_create do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:event_data, event_data})
      {:ok, CreatedEvent.new(event_data.uid, provider_event_id: "g-block")}
    end)
  end

  defp periods(host), do: TimeOff.list(host.profile_id)

  describe "with a writable calendar that blocks availability" do
    test "writes a busy event to the default calendar", host do
      integration =
        google(host, [
          %{"id" => "family", "name" => "Family", "selected" => true},
          %{"id" => "work", "name" => "Work", "selected" => true, "primary" => true}
        ])

      expect_create()

      assert {:ok, %{kind: :event, event: event}} =
               Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")

      assert_receive {:event_data, event_data}
      assert event_data.transparency == "opaque"
      assert event_data.summary == "Focus"
      assert Map.get(event_data, :attendees, []) == []

      assert event.calendar_integration_id == integration.id
      assert event.provider_calendar_id == "work"
      assert event.transparency == "opaque"
      assert event.summary == "Focus"
      assert DateTime.compare(event.start_at, host.start_at) == :eq
      assert periods(host) == []
    end

    test "undo deletes the event", host do
      integration = google(host, [%{"id" => "work", "name" => "Work", "selected" => true}])
      expect_create()
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      {:ok, result} = Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")

      assert :ok = Changes.unblock_time(host.user.id, result)

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, result.event.uid)
    end

    for {what, change} <- [
          moved: [start_at: ~U[2030-01-01 08:00:00.000000Z]],
          resized: [end_at: ~U[2030-12-31 23:00:00.000000Z]],
          renamed: [summary: "Lunch with Ada"]
        ] do
      test "undo leaves an event #{what} since alone and says it changed", host do
        integration = google(host, [%{"id" => "work", "name" => "Work", "selected" => true}])
        expect_create()
        {:ok, result} = Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")

        {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, result.event.uid)
        row |> Changeset.change(unquote(Macro.escape(change))) |> Repo.update!()

        assert {:error, :changed} = Changes.unblock_time(host.user.id, result)
        assert {:ok, _kept} = ProviderCalendarEventQueries.get_by_uid(integration.id, row.uid)
      end
    end

    test "a write queued for a retry is reported as queued, not turned into time off", host do
      insert(:calendar_integration,
        user: host.user,
        provider: "caldav",
        is_active: true,
        calendar_paths: ["/cal/"],
        calendar_list: [%{"id" => "/cal/", "name" => "Work", "selected" => true}]
      )

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:error, :network_error}
      end)

      assert {:error, {:queued, :network_error}} =
               Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")

      assert periods(host) == []
    end

    test "undo of another user's event block is refused", host do
      google(host, [%{"id" => "work", "name" => "Work", "selected" => true}])
      expect_create()
      {:ok, result} = Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")
      %{user: other} = create_bookable_profile()

      assert {:error, :not_found} = Changes.unblock_time(other.id, result)
    end

    test "a failed write is reported, not turned into time off", host do
      google(host, [%{"id" => "work", "name" => "Work", "selected" => true}])

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:error, :unauthorized}
      end)

      assert {:error, _reason} =
               Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")

      assert periods(host) == []
    end
  end

  describe "with no calendar to write a block to" do
    test "takes the time off, and the booking page stops offering it", host do
      assert "1:00 PM" in offered(host.profile, host.date, 30)

      assert {:ok, %{kind: :time_off, period: period}} =
               Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")

      assert period.starts_on == host.date
      assert period.ends_on == host.date
      assert period.start_time == ~T[13:00:00]
      assert period.end_time == ~T[14:00:00]
      assert period.label == "Focus"

      page = offered(host.profile, host.date, 30)
      refute "1:00 PM" in page
      refute "1:30 PM" in page
      assert "11:00 AM" in page
    end

    test "only read-only, show-only or subscribed calendars count as none", host do
      google(host, [
        %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true},
        %{"id" => "kids", "name" => "Kids", "selected" => true, "blocks_availability" => false}
      ])

      insert(:calendar_integration, user: host.user, provider: "ics_url", is_active: true)

      assert {:ok, %{kind: :time_off}} =
               Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")
    end

    test "reads the block on the organiser's clock, and to midnight as the end of the day" do
      host = create_bookable_profile(timezone: "Europe/Berlin")
      date = next_bookable_weekday()

      assert {:ok, %{period: period}} =
               Changes.block_time(
                 host.user.id,
                 DateTime.new!(date, ~T[20:00:00], "Europe/Berlin"),
                 DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Europe/Berlin"),
                 "Evening"
               )

      assert period.starts_on == date
      assert period.ends_on == date
      assert period.start_time == ~T[20:00:00]
      assert period.end_time == nil
    end

    test "a block already under way starts now", host do
      start_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      end_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, %{kind: :time_off, period: period}} =
               Changes.block_time(host.user.id, start_at, end_at, "Focus")

      {:ok, profile} = Profiles.get_profile_by_user_id(host.user.id)
      zone = Profiles.timezone(profile)
      now = DateTime.shift_zone!(DateTime.utc_now(), zone)

      assert period.start_time != DateTime.to_time(DateTime.shift_zone!(start_at, zone))

      assert period.starts_on == DateTime.to_date(now)
      assert abs(Time.diff(period.start_time, DateTime.to_time(now))) < 120
    end

    test "a block years away is too far ahead", host do
      start_at = DateTime.add(host.start_at, 20 * 365, :day)

      assert {:error, :too_far} =
               Changes.block_time(
                 host.user.id,
                 start_at,
                 DateTime.add(start_at, 3600, :second),
                 "Focus"
               )

      assert periods(host) == []
    end

    test "undo removes the time off, and the page offers the time again", host do
      {:ok, result} = Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")

      assert :ok = Changes.unblock_time(host.user.id, result)

      assert periods(host) == []
      assert "1:00 PM" in offered(host.profile, host.date, 30)
    end

    test "undo refuses another user's block", host do
      {:ok, result} = Changes.block_time(host.user.id, host.start_at, host.end_at, "Focus")
      %{user: other} = create_bookable_profile()

      assert {:error, :not_found} = Changes.unblock_time(other.id, result)
      assert [_period] = periods(host)
    end
  end

  describe "refusals" do
    test "a blank title", host do
      assert {:error, :invalid_title} =
               Changes.block_time(host.user.id, host.start_at, host.end_at, "  ")
    end

    test "an end at or before the start", host do
      assert {:error, :invalid_range} =
               Changes.block_time(host.user.id, host.end_at, host.start_at, "Focus")
    end

    test "a stretch already over", host do
      yesterday = Date.add(Date.utc_today(), -1)

      assert {:error, :in_past} =
               Changes.block_time(
                 host.user.id,
                 DateTime.new!(yesterday, ~T[13:00:00], "Etc/UTC"),
                 DateTime.new!(yesterday, ~T[14:00:00], "Etc/UTC"),
                 "Focus"
               )
    end

    test "more than a week", host do
      assert {:error, :too_long} =
               Changes.block_time(
                 host.user.id,
                 host.start_at,
                 DateTime.add(host.start_at, 8, :day),
                 "Focus"
               )

      assert periods(host) == []
    end
  end
end
