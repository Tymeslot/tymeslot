defmodule Tymeslot.Bookings.CreateLimitsTest do
  @moduledoc """
  Booking-journey coverage for booking limits: a booker attempting to book a
  slot in a period whose daily/weekly/monthly cap is already reached must be
  rejected with `:booking_limit_reached`, on both the per-meeting-type and
  account-wide axes; capacity frees when a booking stops occupying its slot.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.TestMocks

  import Tymeslot.MeetingTestHelpers

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  # Calendar conflict checking is not under test here (limits count Tymeslot
  # bookings, never calendar busy time), so every execute skips it.
  @opts [skip_calendar_check: true]

  # ≥3 days out satisfies the default 3h minimum notice with margin; well
  # inside the 90-day advance window.
  @target_offset_days 5

  defp target_date, do: Date.add(Date.utc_today(), @target_offset_days)

  defp booking_params(user, overrides \\ %{}) do
    Map.merge(
      %{
        date: target_date(),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "Etc/UTC",
        organizer_user_id: user.id
      },
      overrides
    )
  end

  defp form_data do
    %{"name" => "Test Attendee", "email" => "attendee@test.com", "message" => "Hi"}
  end

  defp existing_booking(user, %Date{} = date, time, attrs \\ %{}) do
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

  describe "account-wide limits" do
    test "daily cap blocks the booking once reached, whatever the type" do
      %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_day: 1})
      other_type = insert(:meeting_type, user: user)
      existing_booking(user, target_date(), ~T[10:00:00], %{meeting_type_id: other_type.id})

      assert {:error, :booking_limit_reached} =
               Create.execute(booking_params(user), form_data(), @opts)
    end

    test "a different day is unaffected by the daily cap" do
      %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_day: 1})
      existing_booking(user, Date.add(target_date(), 1), ~T[10:00:00])

      assert {:ok, _meeting} = Create.execute(booking_params(user), form_data(), @opts)
    end

    test "weekly cap blocks any other day of the same Monday-week" do
      %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_week: 1})

      # A Monday at least 3 days out, so the whole week is bookable.
      days_to_monday = rem(8 - Date.day_of_week(Date.utc_today()), 7)
      days_to_monday = if days_to_monday < 3, do: days_to_monday + 7, else: days_to_monday
      monday = Date.add(Date.utc_today(), days_to_monday)

      existing_booking(user, Date.add(monday, 1), ~T[10:00:00])

      assert {:error, :booking_limit_reached} =
               Create.execute(
                 booking_params(user, %{date: Date.add(monday, 2)}),
                 form_data(),
                 @opts
               )

      assert {:ok, _meeting} =
               Create.execute(
                 booking_params(user, %{date: Date.add(monday, 7)}),
                 form_data(),
                 @opts
               )
    end

    test "monthly cap counts bookings anywhere in the enclosing month" do
      %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_month: 1})

      next_month_first =
        Date.utc_today() |> Date.end_of_month() |> Date.add(1)

      existing_booking(user, Date.add(next_month_first, 1), ~T[10:00:00])

      assert {:error, :booking_limit_reached} =
               Create.execute(
                 booking_params(user, %{date: Date.add(next_month_first, 14)}),
                 form_data(),
                 @opts
               )
    end
  end

  describe "per-meeting-type limits" do
    test "daily cap on the type blocks further bookings of that type" do
      %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC"})
      type = insert(:meeting_type, user: user, max_bookings_per_day: 1)
      existing_booking(user, target_date(), ~T[10:00:00], %{meeting_type_id: type.id})

      assert {:error, :booking_limit_reached} =
               Create.execute(
                 booking_params(user, %{meeting_type_id: type.id}),
                 form_data(),
                 @opts
               )
    end

    test "bookings of other types don't count toward the type's cap" do
      %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC"})
      type = insert(:meeting_type, user: user, max_bookings_per_day: 1)
      other_type = insert(:meeting_type, user: user)
      existing_booking(user, target_date(), ~T[10:00:00], %{meeting_type_id: other_type.id})

      assert {:ok, _meeting} =
               Create.execute(
                 booking_params(user, %{meeting_type_id: type.id}),
                 form_data(),
                 @opts
               )
    end
  end

  describe "which bookings count" do
    setup do
      %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_day: 1})
      %{user: user}
    end

    test "cancelled bookings free their capacity", %{user: user} do
      existing_booking(user, target_date(), ~T[10:00:00], %{status: "cancelled"})

      assert {:ok, _meeting} = Create.execute(booking_params(user), form_data(), @opts)
    end

    test "awaiting_payment bookings hold their slot and count", %{user: user} do
      existing_booking(user, target_date(), ~T[10:00:00], %{status: "awaiting_payment"})

      assert {:error, :booking_limit_reached} =
               Create.execute(booking_params(user), form_data(), @opts)
    end

    test "a booking under a pending reschedule request doesn't count", %{user: user} do
      existing_booking(user, target_date(), ~T[10:00:00], %{
        reschedule_requested_at: DateTime.utc_now(:second)
      })

      assert {:ok, _meeting} = Create.execute(booking_params(user), form_data(), @opts)
    end
  end

  describe "host-timezone period boundaries" do
    test "two bookings on one UTC day can fall on different host days" do
      # At UTC+12, 20:00 UTC belongs to the NEXT host day while 10:00 UTC
      # belongs to the current one — the daily cap must not conflate them.
      %{user: user} =
        create_user_with_profile(%{timezone: "Etc/GMT-12", max_bookings_per_day: 1})

      existing_booking(user, target_date(), ~T[20:00:00])

      assert {:ok, _meeting} =
               Create.execute(booking_params(user, %{time: "10:00 AM"}), form_data(), @opts)

      assert {:error, :booking_limit_reached} =
               Create.execute(booking_params(user, %{time: "9:00 PM"}), form_data(), @opts)
    end
  end

  describe "host-created ad-hoc bookings" do
    test "bypass the caps entirely" do
      %{user: user} = create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_day: 1})
      existing_booking(user, target_date(), ~T[10:00:00])

      start_time = DateTime.new!(target_date(), ~T[15:00:00], "Etc/UTC")

      assert {:ok, _meeting} =
               CreateAdHoc.execute(%{
                 title: "Deliberate overbook",
                 start_time: start_time,
                 end_time: DateTime.add(start_time, 30, :minute),
                 attendee_name: "Jane Doe",
                 attendee_email: "jane@example.com",
                 attendee_timezone: "Etc/UTC",
                 organizer_user_id: user.id,
                 calendar_integration_id: nil,
                 calendar_path: nil,
                 video_integration_id: nil
               })
    end
  end
end
