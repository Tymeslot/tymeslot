defmodule Tymeslot.Availability.OfferTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.Policy

  @moduletag :availability
  @moduletag :unit

  describe "config/4" do
    test "carries the meeting type's slot interval" do
      config = Offer.config(nil, %{slot_interval_minutes: 5}, nil, nil)

      assert config.slot_interval_minutes == 5
    end

    test "carries nil when the meeting type has no interval" do
      config = Offer.config(nil, %{slot_interval_minutes: nil}, nil, nil)

      assert config.slot_interval_minutes == nil
    end

    test "carries nil when there is no meeting type at all" do
      config = Offer.config(nil, nil, nil, nil)

      assert config.slot_interval_minutes == nil
    end

    test "carries the limit check and the meeting length it is given" do
      limit_checker = fn _start -> false end

      config = Offer.config(nil, nil, limit_checker, 45)

      assert config.limit_checker == limit_checker
      assert config.duration_minutes == 45
    end

    # The page offers from `config/4` and the submit re-checks against
    # `Policy.scheduling_config/2`. A rule present in one and not the other is
    # how a time comes to be offered and then refused, so the two must carry
    # the same scheduling rules with the same values.
    test "agrees with the submit's scheduling config on every scheduling rule" do
      %{user: user, schedule: schedule} = create_bookable_profile()

      schedule =
        schedule
        |> Changeset.change(
          buffer_minutes: 15,
          min_advance_hours: 6,
          advance_booking_days: 21
        )
        |> Repo.update!()

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 60,
          slot_interval_minutes: 20,
          availability_schedule_id: schedule.id
        )

      offer = Offer.config(schedule, meeting_type, nil, 60)
      submit = Policy.scheduling_config(user.id, meeting_type)

      assert Map.drop(offer, [:limit_checker, :duration_minutes]) ==
               Map.drop(submit, [:owner_timezone])

      assert offer.buffer_minutes == 15
      assert offer.min_advance_hours == 6
      assert offer.max_advance_booking_days == 21
      assert offer.slot_interval_minutes == 20
    end
  end

  describe "duration_minutes/2" do
    test "the meeting type's duration wins over the fallback" do
      assert Offer.duration_minutes(%{duration_minutes: 45}, "90min") == 45
    end

    test "parses a duration slug when there is no meeting type" do
      assert Offer.duration_minutes(nil, "90min") == 90
    end

    test "uses a persisted length in minutes when there is no meeting type" do
      assert Offer.duration_minutes(nil, 75) == 75
    end

    test "falls back when the meeting type carries no duration" do
      assert Offer.duration_minutes(%{duration_minutes: nil}, "20min") == 20
    end

    test "bounds a slug to a day" do
      assert Offer.duration_minutes(nil, "99999min") == 1440
    end

    test "bounds a length in minutes to a day" do
      assert Offer.duration_minutes(nil, 5000) == 1440
    end

    test "resolves anything unparseable to 30 minutes" do
      assert Offer.duration_minutes(nil, "not-a-duration") == 30
      assert Offer.duration_minutes(nil, 0) == 30
      assert Offer.duration_minutes(nil, nil) == 30
    end
  end

  describe "slots_for_date/3" do
    test "refuses a date that does not parse" do
      %{profile: profile} = create_bookable_profile()

      assert {:error, :invalid_format} =
               Offer.slots_for_date(
                 %{profile: profile, user_timezone: "Etc/UTC"},
                 "not-a-date",
                 30
               )
    end
  end
end
