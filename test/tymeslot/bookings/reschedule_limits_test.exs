defmodule Tymeslot.Bookings.RescheduleLimitsTest do
  @moduledoc """
  Booking limits on the reschedule journey. Moving a booking must not count
  the booking itself against the caps (else any move within its current
  period would always fail at cap), but moving into a different, already
  full period must be rejected.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.TestMocks

  import Tymeslot.MeetingTestHelpers

  setup do
    TestMocks.setup_all_mocks()
    %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_day: 1})
    %{user: user}
  end

  defp target_date, do: Date.add(Date.utc_today(), 5)

  defp meeting_on(user, %Date{} = date, time, attrs \\ %{}) do
    start_time = DateTime.new!(date, time, "Etc/UTC")

    insert(
      :meeting,
      Map.merge(
        %{
          organizer_user_id: user.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 60, :minute)
        },
        attrs
      )
    )
  end

  defp reschedule_params(%Date{} = date, time) do
    %{date: Date.to_string(date), time: time, duration: "60min", user_timezone: "Etc/UTC"}
  end

  test "moving a booking within its own day succeeds at cap (self-exclusion)", %{user: user} do
    meeting = meeting_on(user, target_date(), ~T[14:00:00])

    assert {:ok, updated} =
             Reschedule.execute(
               meeting.uid,
               reschedule_params(target_date(), "10:00 AM"),
               %{},
               user.id
             )

    assert DateTime.to_date(updated.start_time) == target_date()
    assert updated.start_time.hour == 10
  end

  test "moving a booking into a different, full day is rejected", %{user: user} do
    meeting = meeting_on(user, target_date(), ~T[14:00:00])
    _blocking = meeting_on(user, Date.add(target_date(), 1), ~T[09:00:00])

    assert {:error, :booking_limit_reached} =
             Reschedule.execute(
               meeting.uid,
               reschedule_params(Date.add(target_date(), 1), "2:00 PM"),
               %{},
               user.id
             )
  end

  test "moving into a day filled only by cancelled bookings succeeds", %{user: user} do
    meeting = meeting_on(user, target_date(), ~T[14:00:00])

    _cancelled =
      meeting_on(user, Date.add(target_date(), 1), ~T[09:00:00], %{status: "cancelled"})

    assert {:ok, _updated} =
             Reschedule.execute(
               meeting.uid,
               reschedule_params(Date.add(target_date(), 1), "2:00 PM"),
               %{},
               user.id
             )
  end
end
