defmodule Tymeslot.Bookings.CreateSharedAvailabilityTest do
  @moduledoc """
  Booking a host together with other Tymeslot users named in the link
  (`?with=`): they are re-checked on submit and added as guests.

  The calendar check is skipped throughout, so these tests pin the schedule,
  hosted-booking and guest rules without a calendar provider in the way.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.Guests

  @afternoon %{is_available: true, start_time: ~T[13:00:00], end_time: ~T[17:00:00]}

  setup do
    # No calendar integration to write to: the booking still persists, which is
    # all these tests look at.
    Mox.stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    %{user: host} =
      create_always_bookable_profile(profile: %{username: "marco"}, timezone: "Etc/UTC")

    meeting_type = insert(:meeting_type, user: host, allow_guests: true, duration_minutes: 30)

    %{user: michael} =
      create_bookable_profile(
        profile: %{username: "michael"},
        days: Enum.to_list(1..7),
        hours: @afternoon
      )

    insert(:calendar_integration, user: michael)
    insert(:meeting_type, user: michael)

    %{host: host, michael: michael, meeting_type: meeting_type, date: next_bookable_weekday()}
  end

  defp params(ctx, time, extra \\ %{}) do
    Map.merge(
      %{
        date: ctx.date,
        time: time,
        duration: "30min",
        user_timezone: "Etc/UTC",
        organizer_user_id: ctx.host.id,
        meeting_type_id: ctx.meeting_type.id,
        shared_availability_usernames: ["michael"]
      },
      extra
    )
  end

  @form %{"name" => "Booker", "email" => "booker@example.com"}

  test "books a time the named user is free for and invites them as a guest", ctx do
    assert {:ok, meeting} =
             Create.execute(
               params(ctx, "14:00", %{guest_emails: ["friend@example.com"]}),
               @form,
               skip_calendar_check: true
             )

    # Guests of one booking are inserted within the same second, so the order
    # they are listed in is not defined; that named users come first is pinned
    # by `SharedAvailability.merge_guest_emails/2`'s own test.
    emails = meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email) |> Enum.sort()
    assert emails == Enum.sort([ctx.michael.email, "friend@example.com"])
  end

  test "refuses a time outside the named user's working hours", ctx do
    assert {:error, :slot_taken} =
             Create.execute(params(ctx, "10:00"), @form, skip_calendar_check: true)
  end

  test "refuses a time the named user hosts a booking in", ctx do
    start = DateTime.new!(ctx.date, ~T[14:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_user_id: ctx.michael.id,
      start_time: start,
      end_time: DateTime.add(start, 60, :minute),
      status: "confirmed"
    )

    assert {:error, :slot_taken} =
             Create.execute(params(ctx, "14:00"), @form, skip_calendar_check: true)
  end

  test "refuses a meeting type that does not allow guests", ctx do
    no_guests = insert(:meeting_type, user: ctx.host, allow_guests: false, duration_minutes: 30)

    assert {:error, :booking_failed} =
             Create.execute(
               params(ctx, "14:00", %{meeting_type_id: no_guests.id}),
               @form,
               skip_calendar_check: true
             )
  end

  test "refuses a named user who can no longer be booked", ctx do
    assert {:error, :booking_failed} =
             Create.execute(
               params(ctx, "14:00", %{shared_availability_usernames: ["nobody"]}),
               @form,
               skip_calendar_check: true
             )
  end

  test "leaves a booking without named users on the host's rules alone", ctx do
    assert {:ok, meeting} =
             Create.execute(
               params(ctx, "10:00", %{shared_availability_usernames: []}),
               @form,
               skip_calendar_check: true
             )

    assert Guests.list_for_meeting(meeting.id) == []
  end
end
