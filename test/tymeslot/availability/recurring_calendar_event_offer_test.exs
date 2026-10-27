defmodule Tymeslot.Availability.RecurringCalendarEventOfferTest do
  @moduledoc """
  The booking page against a recurring event from a CalDAV-shaped calendar,
  expanded by the real read path rather than handed over as occurrences.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.Runtime.EventsRead
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  # A CalDAV-shaped provider: it returns a recurring event as its master,
  # with the rule, and leaves the expansion to the read path.
  defmodule StandingMeetingProvider do
    @moduledoc false

    @spec list_events(map(), keyword()) :: {:ok, [map()]}
    def list_events(%{first_day: first_day}, _opts) do
      {:ok,
       [
         %{
           uid: "standing-standup",
           summary: "Standup",
           start_time: DateTime.new!(first_day, ~T[11:00:00], "Etc/UTC"),
           end_time: DateTime.new!(first_day, ~T[11:30:00], "Etc/UTC"),
           recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
           status: "confirmed",
           transparency: "opaque"
         }
       ]}
    end

    @spec convert_events([map()]) :: [map()]

    def convert_events(events), do: events
  end

  # A CalDAV server's answer for a `TZID=Europe/Berlin` weekly series, run
  # through the real parser: the maps carry the UTC start and the zone just
  # as the CalDAV read path hands them over, and the override comes back as
  # its own VEVENT beside the master.
  defmodule BerlinSeriesProvider do
    @moduledoc false

    @spec list_events(map(), keyword()) :: {:ok, [map()]}
    def list_events(%{first_day: first_day, moved_day: moved_day}, _opts) do
      ICalParser.parse("""
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//EN
      BEGIN:VEVENT
      UID:berlin-weekly
      DTSTART;TZID=Europe/Berlin:#{basic(first_day)}T130000
      DTEND;TZID=Europe/Berlin:#{basic(first_day)}T133000
      RRULE:FREQ=WEEKLY
      SUMMARY:Weekly sync
      END:VEVENT
      BEGIN:VEVENT
      UID:berlin-weekly
      RECURRENCE-ID;TZID=Europe/Berlin:#{basic(moved_day)}T130000
      DTSTART;TZID=Europe/Berlin:#{basic(moved_day)}T150000
      DTEND;TZID=Europe/Berlin:#{basic(moved_day)}T153000
      SUMMARY:Weekly sync (moved)
      END:VEVENT
      END:VCALENDAR
      """)
    end

    defp basic(date), do: Date.to_iso8601(date, :basic)

    @spec convert_events([map()]) :: [map()]

    def convert_events(events), do: events
  end

  describe "a recurring calendar event that began years ago" do
    test "still hides its slot today, and the booking API refuses it" do
      %{user: user, profile: profile} = create_bookable_profile(timezone: "Etc/UTC")
      target_date = next_bookable_weekday()

      # Three years of weekdays is far more occurrences than one expansion
      # returns, so the series has to be moved forward to the range rather
      # than counted from its first day.
      client = %{
        provider_type: :fake,
        provider_module: StandingMeetingProvider,
        client: %{calendar_path: "/cal/standing", first_day: Date.add(target_date, -3 * 364)}
      }

      TestMocks.stub_no_calendar_events()
      assert "11:00 AM" in offered(profile, target_date, "30min")

      # The stub hands the range to the real read path, which expands the rule.
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
        {:ok, events, _path} =
          EventsRead.fetch_events_with_fallback(
            client,
            DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
            DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")
          )

        {:ok, events}
      end)

      AvailabilityCache.invalidate_for_user(user.id)
      slots = offered(profile, target_date, "30min")

      refute "11:00 AM" in slots
      assert "12:00 PM" in slots

      assert {:error, :slot_taken} =
               Create.execute(
                 %{
                   date: target_date,
                   time: "11:00 AM",
                   duration: "30min",
                   user_timezone: "Etc/UTC",
                   organizer_user_id: user.id
                 },
                 %{
                   "name" => "Standup Attendee",
                   "email" => "standup-attendee@example.com",
                   "message" => "Booking over a standing meeting"
                 }
               )
    end
  end

  describe "a CalDAV series created on the other side of a DST change" do
    test "blocks its local time, and a moved occurrence only its new time" do
      %{user: user, profile: profile} = create_bookable_profile(timezone: "Europe/Berlin")
      target_date = next_bookable_weekday()
      moved_day = Date.add(target_date, 7)

      # The series' first day is the same weekday, far enough back that
      # Berlin was on the other offset: read in UTC rather than in its zone,
      # the series would block an hour either side of 13:00 instead.
      client = %{
        provider_type: :fake,
        provider_module: BerlinSeriesProvider,
        client: %{
          calendar_path: "/cal/berlin",
          first_day: other_offset_day(target_date),
          moved_day: moved_day
        }
      }

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
        {:ok, events, _path} =
          EventsRead.fetch_events_with_fallback(
            client,
            DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
            DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")
          )

        {:ok, events}
      end)

      AvailabilityCache.invalidate_for_user(user.id)
      slots = offered(profile, target_date, "30min")

      refute "1:00 PM" in slots
      assert "12:00 PM" in slots
      assert "2:00 PM" in slots

      moved_slots = offered(profile, moved_day, "30min")

      assert "1:00 PM" in moved_slots
      refute "3:00 PM" in moved_slots

      assert {:error, :slot_taken} =
               Create.execute(
                 %{
                   date: target_date,
                   time: "1:00 PM",
                   duration: "30min",
                   user_timezone: "Europe/Berlin",
                   organizer_user_id: user.id
                 },
                 %{
                   "name" => "Sync Attendee",
                   "email" => "sync-attendee@example.com",
                   "message" => "Booking over a weekly sync"
                 }
               )
    end
  end

  defp other_offset_day(date) do
    offset = berlin_offset(date)

    1
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&Date.add(date, -7 * &1))
    |> Enum.find(&(berlin_offset(&1) != offset))
  end

  defp berlin_offset(date) do
    local = DateTime.new!(date, ~T[13:00:00], "Europe/Berlin")
    local.utc_offset + local.std_offset
  end
end
