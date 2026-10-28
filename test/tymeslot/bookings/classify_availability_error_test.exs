defmodule Tymeslot.Bookings.ClassifyAvailabilityErrorTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory

  alias Tymeslot.Bookings.Errors

  @moduletag :bookings
  @moduletag :calendar

  describe "classify_availability_error/2" do
    test "an unreadable calendar whose credentials were refused is a disconnected host calendar" do
      user = insert(:user)
      insert(:calendar_integration, user: user, is_active: true, needs_reauth: true)

      assert Errors.classify_availability_error(:all_calendars_unavailable, user.id) ==
               :host_calendar_disconnected
    end

    test "an unreadable calendar with no refused credentials stays unverifiable" do
      user = insert(:user)
      insert(:calendar_integration, user: user, is_active: true)

      assert Errors.classify_availability_error(:all_calendars_unavailable, user.id) ==
               :availability_unverifiable
    end

    test "a failure other than an unreadable calendar is classified as classify_error/1 does" do
      user = insert(:user)
      insert(:calendar_integration, user: user, is_active: true, needs_reauth: true)

      assert Errors.classify_availability_error(:slot_unavailable, user.id) == :slot_taken
    end

    test "with no organiser it is classified as classify_error/1 does" do
      assert Errors.classify_availability_error(:all_calendars_unavailable, nil) ==
               :availability_unverifiable
    end
  end
end
