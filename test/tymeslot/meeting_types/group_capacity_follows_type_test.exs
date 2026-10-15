defmodule Tymeslot.MeetingTypes.GroupCapacityFollowsTypeTest do
  @moduledoc """
  What changing a meeting type's `max_participants` does to the meetings it
  already has: a one-to-one booking stays private when the type becomes a
  group type, a group meeting's capacity follows a new limit above one, and
  a type turned back to one seat stops taking joins and seat moves.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types
  @moduletag :bookings
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.GroupSlots
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.RescheduleSeat
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo

  @timezone "Etc/UTC"

  setup do
    %{user: user, profile_id: profile_id} = create_bookable_profile(timezone: @timezone)
    date = next_bookable_weekday()

    config = %{
      profile_id: profile_id,
      max_advance_booking_days: 90,
      min_advance_hours: 3,
      buffer_before_minutes: 15,
      buffer_after_minutes: 15
    }

    %{user: user, date: date, config: config, start_time: DateTime.new!(date, ~T[11:00:00])}
  end

  defp meeting_at(ctx, factory, meeting_type, start_time, attrs) do
    insert(
      factory,
      Keyword.merge(
        [
          organizer_user_id: ctx.user.id,
          organizer_email: ctx.user.email,
          meeting_type_id: meeting_type.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute),
          duration: 30
        ],
        attrs
      )
    )
  end

  defp seat_request(email, max_participants) do
    %{
      participant: %{
        name: "Booker",
        email: email,
        timezone: @timezone,
        locale: "en",
        custom_field_answers: %{}
      },
      guest_emails: [],
      max_participants: max_participants
    }
  end

  defp slot_attrs(ctx, meeting_type, start_time) do
    %{
      uid: UUID.generate(),
      title: meeting_type.name,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed",
      organizer_user_id: ctx.user.id,
      organizer_name: "Organiser",
      organizer_email: ctx.user.email,
      meeting_type_id: meeting_type.id
    }
  end

  defp capacity(meeting), do: Repo.get!(MeetingSchema, meeting.id).capacity

  describe "a type switched to group bookings" do
    setup ctx do
      meeting_type =
        insert(:meeting_type,
          user: ctx.user,
          max_participants: 1,
          duration_minutes: 30,
          locations: [in_person_location([insert(:venue, user: ctx.user)])]
        )

      solo =
        meeting_at(ctx, :meeting, meeting_type, ctx.start_time,
          attendee_name: "Private Booker",
          attendee_email: "private@example.com"
        )

      {:ok, group_type} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})

      %{group_type: group_type, solo: solo}
    end

    test "leaves an existing one-to-one booking solo, with no participant and no email",
         %{solo: solo} do
      reloaded = Repo.get!(MeetingSchema, solo.id)

      assert reloaded.capacity == 1
      assert reloaded.attendee_email == "private@example.com"
      assert ParticipantQueries.list_live_for_meeting(solo.id) == []
      assert all_enqueued() == []
    end

    test "the one-to-one booking keeps its slot: it is not joinable and refuses a seat",
         %{group_type: group_type, solo: solo} = ctx do
      assert GroupScheduling.join_target(group_type.id, ctx.start_time, 1) == nil

      # Even before the booking's calendar event has synced (no events at
      # all), the slot is not offered with seats.
      {:ok, starts} =
        Calculate.available_starts(ctx.date, 30, @timezone, @timezone, [], ctx.config)

      assert "11:00 AM" in Enum.map(starts, &TimeSlots.format_datetime_slot/1)

      context = %{
        user_timezone: @timezone,
        owner_timezone: @timezone,
        events: [],
        config: ctx.config
      }

      enriched = GroupSlots.enrich_day_slots(starts, group_type, ctx.date, context)
      refute Enum.any?(enriched, &(&1.time == "11:00 AM"))

      assert {:error, :slot_full} =
               GroupScheduling.book_seat(
                 slot_attrs(ctx, group_type, ctx.start_time),
                 seat_request("stranger@example.com", 4)
               )

      assert ParticipantQueries.list_live_for_meeting(solo.id) == []
    end
  end

  describe "changing a group type's limit to another group limit" do
    test "updates capacity on future live group meetings only", ctx do
      meeting_type =
        insert(:meeting_type,
          user: ctx.user,
          max_participants: 4,
          duration_minutes: 30,
          locations: [in_person_location([insert(:venue, user: ctx.user)])]
        )

      future = meeting_at(ctx, :group_meeting, meeting_type, ctx.start_time, capacity: 4)

      past =
        meeting_at(ctx, :group_meeting, meeting_type, DateTime.add(ctx.start_time, -30, :day),
          capacity: 4
        )

      cancelled =
        meeting_at(ctx, :group_meeting, meeting_type, DateTime.add(ctx.start_time, 2, :hour),
          capacity: 4,
          status: "cancelled"
        )

      solo =
        meeting_at(ctx, :meeting, meeting_type, DateTime.add(ctx.start_time, 4, :hour),
          capacity: 1
        )

      assert {:ok, _type} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 6})

      assert capacity(future) == 6
      assert capacity(past) == 4
      assert capacity(cancelled) == 4
      assert capacity(solo) == 1
    end

    test "a capacity below the seats taken leaves the slot exactly full without cancelling anyone",
         ctx do
      meeting_type =
        insert(:meeting_type,
          user: ctx.user,
          max_participants: 6,
          duration_minutes: 30,
          locations: [in_person_location([insert(:venue, user: ctx.user)])]
        )

      meeting = meeting_at(ctx, :group_meeting, meeting_type, ctx.start_time, capacity: 6)

      [first | _rest] =
        for n <- 1..3, do: insert(:participant, meeting: meeting, email: "p#{n}@example.com")

      # A guest takes a seat like their participant does.
      {:ok, [_guest]} =
        Guests.create_for_participant(meeting.id, first.id, ["guest@example.com"])

      {:ok, lowered} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 2})

      assert capacity(meeting) == 4
      assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 3

      assert {:error, :slot_full} =
               GroupScheduling.book_seat(
                 slot_attrs(ctx, lowered, ctx.start_time),
                 seat_request("late@example.com", 2)
               )
    end
  end

  describe "a group type turned back to one seat" do
    setup ctx do
      meeting_type =
        insert(:meeting_type,
          user: ctx.user,
          max_participants: 4,
          duration_minutes: 30,
          locations: [in_person_location([insert(:venue, user: ctx.user)])]
        )

      meeting = meeting_at(ctx, :group_meeting, meeting_type, ctx.start_time, capacity: 4)
      participant = insert(:participant, meeting: meeting, email: "seated@example.com")

      {:ok, solo_type} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 1})

      %{solo_type: solo_type, meeting: meeting, participant: participant}
    end

    test "keeps the group meeting's capacity and its seats", %{meeting: meeting} do
      assert capacity(meeting) == 4

      assert [%{email: "seated@example.com"}] =
               ParticipantQueries.list_live_for_meeting(meeting.id)
    end

    test "the slot refuses new joins and is not offered as joinable",
         %{solo_type: solo_type, meeting: meeting} = ctx do
      # The meeting's own calendar event blocks the slot, and a type that is
      # no longer a group type does not unblock it for a seat.
      event = %{
        uid: meeting.calendar_uid,
        start_time: meeting.start_time,
        end_time: meeting.end_time
      }

      {:ok, starts} =
        Calculate.available_starts(ctx.date, 30, @timezone, @timezone, [event], ctx.config)

      context = %{
        user_timezone: @timezone,
        owner_timezone: @timezone,
        events: [event],
        config: ctx.config
      }

      refute Enum.any?(
               GroupSlots.enrich_day_slots(starts, solo_type, ctx.date, context),
               &(&1.time == "11:00 AM")
             )

      assert {:error, :slot_full} =
               GroupScheduling.book_seat(
                 slot_attrs(ctx, solo_type, ctx.start_time),
                 seat_request("newcomer@example.com", solo_type.max_participants)
               )

      assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
    end

    test "a seat move out of the group meeting is refused",
         %{participant: participant, meeting: meeting} = ctx do
      new_params = %{
        date: Date.to_iso8601(Date.add(ctx.date, 1)),
        time: "10:00",
        duration: "30min",
        user_timezone: @timezone
      }

      assert {:error, :seat_not_movable} =
               RescheduleSeat.execute(
                 participant.management_token,
                 new_params,
                 meeting.organizer_user_id
               )

      assert [%{id: id, cancelled_at: nil}] = ParticipantQueries.list_live_for_meeting(meeting.id)
      assert id == participant.id
    end

    test "a seat move into another group meeting of the type is refused",
         %{solo_type: solo_type, participant: participant, meeting: meeting} = ctx do
      target_start = DateTime.add(ctx.start_time, 2, :hour)
      target = meeting_at(ctx, :group_meeting, solo_type, target_start, capacity: 4)

      new_params = %{
        date: Date.to_iso8601(ctx.date),
        time: "13:00",
        duration: "30min",
        user_timezone: @timezone
      }

      assert {:error, :seat_not_movable} =
               RescheduleSeat.execute(
                 participant.management_token,
                 new_params,
                 meeting.organizer_user_id
               )

      assert ParticipantQueries.list_live_for_meeting(target.id) == []
    end
  end
end
