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
    :failed_to_update_meeting
  ]

  describe "message/1 with classified error atoms" do
    test "covers every atom in Errors.classified_error/0 with a translated, non-leaking message" do
      assert length(@classified_errors) == 11

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

    test "renders exact copy for each classified error atom" do
      assert BookingErrorMessage.message(:slot_taken) ==
               "This time slot is no longer available. Please select a different time."

      assert BookingErrorMessage.message(:meeting_type_inactive) ==
               "This meeting type is no longer available. Please refresh the page."

      assert BookingErrorMessage.message(:meeting_type_not_found) ==
               "This meeting type is no longer available. Please go back and select another."

      assert BookingErrorMessage.message(:organizer_required) ==
               "Organizer is required for booking"

      assert BookingErrorMessage.message(:booking_failed) ==
               "Failed to save meeting to database"

      assert BookingErrorMessage.message(:payments_unavailable) ==
               "Payments are not available for this booking. Please contact the host."

      assert BookingErrorMessage.message(:host_not_found) ==
               "Host could not be found. Please refresh and try again."

      assert BookingErrorMessage.message(:custom_field_errors) ==
               "Please fill in all required fields before submitting."

      assert BookingErrorMessage.message(:checkout_failed) ==
               "We couldn't start the payment process. Please try again."

      assert BookingErrorMessage.message(:meeting_not_found) ==
               "This meeting could not be found. Please refresh and try again."

      assert BookingErrorMessage.message(:failed_to_update_meeting) ==
               "Failed to process booking. Please try again."
    end
  end

  describe "message/1 with binary reasons" do
    test "passes short binaries through unchanged" do
      reason = "Some short custom error"
      assert String.length(reason) < 100
      assert BookingErrorMessage.message(reason) == reason
    end

    test "falls back to generic copy for binaries at or above 100 chars" do
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
