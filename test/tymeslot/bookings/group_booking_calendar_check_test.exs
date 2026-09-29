defmodule Tymeslot.Bookings.GroupBookingCalendarCheckTest do
  @moduledoc """
  Joining a live group meeting through the booking page and its submit.

  The group meeting is already in the host's calendar, written there by
  Tymeslot when its first seat was booked, and it is also one of the host's
  own bookings. Both the page's offer and the submit's fresh calendar read
  would count it as busy, so each has to recognise the meeting's own entry
  as the slot being joined rather than a conflict: otherwise every group
  slot closes after its first booker. Anything else at that time still
  blocks it.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.TestMocks

  @timezone "Etc/UTC"

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()

    %{user: user, profile: profile} = create_always_bookable_profile(timezone: @timezone)

    meeting_type =
      insert(:meeting_type, user: user, duration_minutes: 30, max_participants: 3)

    date = Date.add(Date.utc_today(), 5)

    meeting_params = %{
      date: date,
      time: "10:00",
      duration: "30min",
      user_timezone: @timezone,
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    # The first seat creates the meeting; its calendar write is what the rest
    # of these tests then find in the host's calendar.
    {:ok, meeting} =
      Create.execute(meeting_params, form_data("first@example.com"), skip_calendar_check: true)

    %{
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      meeting_params: meeting_params,
      date: date
    }
  end

  describe "the group meeting's own entry in the host's calendar" do
    test "keeps the slot offered with the seats it has left", context do
      stub_calendar_events([ten_oclock_event(context, uid: context.meeting.calendar_uid)])

      assert %{seats_left: 2, capacity: 3} = ten_oclock_slot(context)
    end

    test "lets a second booker join through the fresh calendar check", context do
      stub_calendar_events([ten_oclock_event(context, uid: context.meeting.calendar_uid)])

      assert {:ok, joined} =
               Create.execute(context.meeting_params, form_data("second@example.com"))

      assert joined.id == context.meeting.id

      assert context.meeting.id
             |> ParticipantQueries.list_live_for_meeting()
             |> Enum.map(& &1.email)
             |> Enum.sort() == ["first@example.com", "second@example.com"]
    end
  end

  # The anchor for the two above: the same time held by anything else is still
  # a conflict, so they pass because the meeting's own entry is recognised and
  # not because the calendar is never consulted.
  describe "another event at the same time" do
    test "closes the slot and refuses the booking", context do
      stub_calendar_events([ten_oclock_event(context, uid: "someone-elses-event")])

      assert ten_oclock_slot(context) == nil

      assert {:error, :slot_taken} =
               Create.execute(context.meeting_params, form_data("second@example.com"))

      assert [_first] = ParticipantQueries.list_live_for_meeting(context.meeting.id)
    end
  end

  defp form_data(email) do
    %{"name" => "Booker #{email}", "email" => email, "message" => "hello"}
  end

  defp ten_oclock_slot(%{profile: profile, meeting_type: meeting_type, date: date}) do
    AvailabilityCache.clear_all()

    {:ok, slots} =
      Offer.slots_for_date(
        %{profile: profile, user_timezone: @timezone, meeting_type: meeting_type},
        Date.to_iso8601(date),
        30
      )

    Enum.find(slots, &(&1.time == "10:00 AM"))
  end

  defp ten_oclock_event(%{date: date}, opts) do
    TestMocks.mock_calendar_event(
      Keyword.merge(
        [
          summary: "Group meeting",
          start_time: DateTime.new!(date, ~T[10:00:00], @timezone),
          end_time: DateTime.new!(date, ~T[10:30:00], @timezone)
        ],
        opts
      )
    )
  end

  defp stub_calendar_events(events) do
    TestMocks.setup_calendar_mocks(result: {:ok, events})
    AvailabilityCache.clear_all()
  end
end
