defmodule TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessageTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :unit

  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage

  # Keep in sync with `Tymeslot.Bookings.Errors.classified_error/0` — a new
  # atom added there without a matching entry (and `message/1` clause) here
  # should fail this test.
  @classified_errors [
    :meeting_type_inactive,
    :meeting_type_not_found,
    :slot_taken,
    :organizer_required,
    :booking_failed,
    :payments_unavailable,
    :host_not_found,
    :custom_field_errors,
    :checkout_failed,
    :meeting_not_found,
    :failed_to_update_meeting,
    :booking_limit_reached
  ]

  describe "message/1 with classified error atoms" do
    test "covers every atom in Errors.classified_error/0 with a translated, non-leaking message" do
      results =
        for reason <- @classified_errors do
          message = BookingErrorMessage.message(reason)

          assert is_binary(message) and message != "",
                 "expected #{inspect(reason)} to render a non-empty string"

          refute message =~ Atom.to_string(reason),
                 "expected #{inspect(reason)} to be translated, not leaked as its atom name"

          message
        end

      assert MapSet.size(MapSet.new(results)) == length(@classified_errors),
             "expected every classified error atom to render a distinct message"
    end
  end

  # One entry per refusal `Tymeslot.Bookings.Policy`, `Validation` and
  # `CreateAdHoc` return (`Tymeslot.Bookings.Refusal.t/0` and the ad-hoc
  # atoms), with the copy it must render. A refusal added there without a
  # `message/1` clause falls to the generic fallback and fails here.
  @refusals %{
    {:not_cancellable, :completed} => "Cannot cancel a completed meeting",
    {:not_cancellable, :expired} => "Cannot cancel an expired meeting",
    {:not_cancellable, :started} => "Cannot cancel a meeting that has already started",
    {:not_cancellable, :past} => "Cannot cancel a meeting that has already occurred",
    {:not_reschedulable, :cancelled} => "Cannot reschedule a cancelled meeting",
    {:not_reschedulable, :completed} => "Cannot reschedule a completed meeting",
    {:not_reschedulable, :expired} => "Cannot reschedule an expired meeting",
    {:not_reschedulable, :started} => "Cannot reschedule a meeting that has already started",
    {:not_reschedulable, :past} => "Cannot reschedule a meeting that has already occurred",
    {:not_reschedulable, :awaiting_approval} =>
      "Cannot request a reschedule while the booking awaits approval",
    :invalid_datetime => "Invalid date/time",
    :in_past => "Booking time must be in the future",
    {:too_soon, 12} => "Booking requires at least 12 hours in advance",
    {:too_far_ahead, 90} => "You cannot book more than 90 days in advance",
    :title_required => "Title is required",
    :attendee_name_required => "Attendee name is required",
    :attendee_email_required => "Attendee email is required",
    :attendee_is_organizer => "The guest email must differ from your own address",
    :end_before_start => "End time must be after start time",
    :meeting_creation_failed => "Failed to create meeting"
  }

  describe "message/1 with booking-rule refusals" do
    test "renders each refusal as its own copy" do
      mismatches =
        for {reason, expected} <- @refusals,
            BookingErrorMessage.message(reason) != expected,
            do: {reason, BookingErrorMessage.message(reason)}

      assert mismatches == []
    end

    test "renders a refusal in the visitor's locale" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert BookingErrorMessage.message({:not_cancellable, :expired}) ==
                 "Ein abgelaufener Termin kann nicht abgesagt werden"
      end)
    end
  end

  describe "message/1 with binary reasons" do
    test "falls back to generic copy instead of leaking raw English" do
      reason = "Some short custom error"

      assert BookingErrorMessage.message(reason) ==
               "Failed to create appointment. Please try again."
    end

    test "falls back to generic copy for a long unmapped binary" do
      reason = String.duplicate("x", 100)

      assert BookingErrorMessage.message(reason) ==
               "Failed to create appointment. Please try again."
    end
  end

  describe "message/1 with unknown atoms" do
    test "falls back to generic copy for an unmapped atom" do
      assert BookingErrorMessage.message(:some_unmapped_atom) ==
               "Failed to create appointment. Please try again."
    end
  end
end
