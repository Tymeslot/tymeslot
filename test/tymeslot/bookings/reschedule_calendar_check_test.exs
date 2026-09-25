defmodule Tymeslot.Bookings.RescheduleCalendarCheckTest do
  @moduledoc """
  The reschedule submit re-reads the host's connected calendar.

  A new booking has always re-read it at submit time; a reschedule did not.
  The reschedule page's grid is drawn from cached, window-fetched events, and
  the write only ever consulted Tymeslot's own meetings table, so a host who
  blocked the time in Google, Outlook or CalDAV after the page rendered could
  still have a meeting moved on top of it.

  The check has to leave the meeting being moved out of the busy set, because
  Tymeslot wrote that meeting into the host's calendar itself: counted, it
  would refuse every move onto a time overlapping or (through the buffer)
  merely adjacent to the slot the booking already occupies, so nothing could
  be nudged by fifteen minutes. The page offers by the same rule, so the grid
  and the submit agree on which times the mover may take.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  @timezone "Etc/UTC"

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()

    %{user: user, profile: profile} = create_always_bookable_profile(timezone: @timezone)

    # Fifteen-minute slots, so the grid is stepped finely enough for the
    # "nudge it by fifteen minutes" move the exclusion exists to allow.
    meeting_type = insert(:meeting_type, user: user, duration_minutes: 15)

    date = Date.add(Date.utc_today(), 5)
    start_time = DateTime.new!(date, ~T[14:00:00], @timezone)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 15, :minute),
        duration: 15,
        provider_event_id: "google-event-#{System.unique_integer([:positive])}"
      )

    %{
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      date: date
    }
  end

  describe "a time the host blocked after the reschedule page rendered" do
    test "is refused, and the meeting keeps its original time", context do
      %{user: user, meeting: meeting, date: date} = context

      # The page rendered while the host's calendar was clear.
      assert "3:00 PM" in slots(context, meeting.uid)

      # The host then blocks it in Google/Outlook/CalDAV.
      stub_calendar_events([
        external_event(date, ~T[15:00:00], ~T[15:30:00])
      ])

      assert {:error, :slot_taken} = reschedule(meeting, date, "3:00 PM", user.id)

      assert {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert DateTime.compare(unchanged.start_time, meeting.start_time) == :eq

      # The grid a reloaded page would draw agrees with the refusal, so the
      # invitee is not sent back to pick the very slot they were just denied.
      refute "3:00 PM" in slots(context, meeting.uid)
    end
  end

  describe "the meeting's own event in the host's calendar" do
    test "does not stop the booking being nudged by fifteen minutes", context do
      %{user: user, meeting: meeting, date: date} = context

      # The booking as Tymeslot wrote it to the host's calendar: same UID,
      # 14:00-14:15, immediately before the slot the invitee wants.
      stub_calendar_events([own_event(context, uid: meeting.uid)])

      assert "2:15 PM" in slots(context, meeting.uid)

      assert {:ok, moved} = reschedule(meeting, date, "2:15 PM", user.id)
      assert moved.start_time == DateTime.new!(date, ~T[14:15:00], @timezone)
    end

    # Google and Outlook do not preserve the UID Tymeslot generated: the event
    # comes back under the provider's own id, which the meeting carries as
    # `provider_event_id`. Matching on `uid` alone would leave every OAuth host
    # unable to nudge a booking.
    test "is recognised by the provider's event id too", context do
      %{user: user, meeting: meeting, date: date} = context

      stub_calendar_events([own_event(context, uid: meeting.provider_event_id)])

      assert "2:15 PM" in slots(context, meeting.uid)

      assert {:ok, moved} = reschedule(meeting, date, "2:15 PM", user.id)
      assert moved.start_time == DateTime.new!(date, ~T[14:15:00], @timezone)
    end

    # The anchor for the two above: an event at exactly the same time that is
    # NOT the meeting being moved does block the nudge, so those tests are
    # passing because of the exclusion rather than because nothing was ever
    # checked.
    test "blocks that same move when it belongs to some other booking", context do
      %{user: user, meeting: meeting, date: date} = context

      stub_calendar_events([own_event(context, uid: "someone-elses-event")])

      refute "2:15 PM" in slots(context, meeting.uid)

      assert {:error, :slot_taken} = reschedule(meeting, date, "2:15 PM", user.id)
    end
  end

  describe "a calendar the host's providers could not fully read" do
    test "refuses the move rather than proving nothing", context do
      %{user: user, meeting: meeting, date: date} = context

      stub_calendar_result({:error, :some_calendars_unavailable})

      assert {:error, :slot_taken} = reschedule(meeting, date, "3:00 PM", user.id)

      assert {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert DateTime.compare(unchanged.start_time, meeting.start_time) == :eq
    end

    # A provider that is merely unreachable is a different case: the busy set
    # was already checked when the grid was drawn, and an outage at Google must
    # not take rescheduling down with it.
    test "still moves the booking when the fetch fails at transport level", context do
      %{user: user, meeting: meeting, date: date} = context

      stub_calendar_result({:error, :econnrefused})

      assert {:ok, moved} = reschedule(meeting, date, "3:00 PM", user.id)
      assert moved.start_time == DateTime.new!(date, ~T[15:00:00], @timezone)
    end
  end

  defp reschedule(meeting, date, time, organizer_user_id) do
    Reschedule.execute(
      meeting.uid,
      %{
        date: Date.to_iso8601(date),
        time: time,
        duration: "15min",
        user_timezone: @timezone
      },
      %{},
      organizer_user_id
    )
  end

  defp slots(%{profile: profile, meeting_type: meeting_type, date: date}, reschedule_uid) do
    AvailabilityCache.clear_all()

    {:ok, slots} =
      Offer.slots_for_date(
        %{
          profile: profile,
          user_timezone: @timezone,
          meeting_type: meeting_type,
          reschedule_uid: reschedule_uid
        },
        Date.to_iso8601(date),
        15
      )

    slots
  end

  defp own_event(%{date: date}, opts) do
    external_event(date, ~T[14:00:00], ~T[14:15:00], opts)
  end

  defp external_event(date, from, to, opts \\ []) do
    TestMocks.mock_calendar_event(
      Keyword.merge(
        [
          summary: "Blocked",
          start_time: DateTime.new!(date, from, @timezone),
          end_time: DateTime.new!(date, to, @timezone)
        ],
        opts
      )
    )
  end

  defp stub_calendar_events(events), do: stub_calendar_result({:ok, events})

  defp stub_calendar_result(result) do
    TestMocks.setup_calendar_mocks(result: result)
    AvailabilityCache.clear_all()
  end
end
