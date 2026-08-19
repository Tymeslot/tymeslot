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

  # Keep in sync with the exact-match legacy binaries `Tymeslot.Bookings.*`
  # still returns as `{:error, "..."}` — a new one added there without a
  # matching `legacy_message/1` clause here silently degrades to the
  # generic fallback instead of failing loudly.
  @legacy_exact_binaries [
    "Invalid date or time format",
    "Invalid date format",
    "Meeting is already cancelled",
    "Cannot cancel a completed meeting",
    "Cannot cancel a meeting that has already started",
    "Cannot cancel a meeting that has already occurred",
    "Cannot reschedule a cancelled meeting",
    "Cannot reschedule a completed meeting",
    "Cannot reschedule a meeting that has already started",
    "Cannot reschedule a meeting that has already occurred",
    "Booking time must be in the future",
    "Attendee email is required",
    "Attendee name is required",
    "End time must be after start time",
    "Failed to create meeting",
    "Failed to update meeting status",
    "The guest email must differ from your own address",
    "Title is required"
  ]

  describe "message/1 with legacy exact-match binary reasons" do
    test "translates every mapped legacy binary to a non-leaking message" do
      for reason <- @legacy_exact_binaries do
        message = BookingErrorMessage.message(reason)

        assert is_binary(message) and message != "",
               "expected #{inspect(reason)} to render a non-empty string"

        refute message == "Failed to create appointment. Please try again.",
               "expected #{inspect(reason)} to have its own mapped message, not the generic fallback"
      end
    end

    # "Invalid date format" and "Invalid date or time format" deliberately
    # share a message: both reuse the msgid `localization_helpers.ex` already
    # defines (and every locale already translates) for the same underlying
    # problem, rather than adding new, untranslated near-duplicate strings.
    test "shares one message between the two invalid-date/time variants" do
      assert BookingErrorMessage.message("Invalid date format") ==
               BookingErrorMessage.message("Invalid date or time format")
    end
  end

  describe "message/1 with legacy interpolated binary reasons" do
    test "extracts the hour count from Validation's notice-window variants" do
      assert BookingErrorMessage.message("Booking requires at least 3 hours in advance") =~
               "3 hours"

      assert BookingErrorMessage.message("Booking requires at least 12 hours advance notice") =~
               "12 hours"
    end

    test "extracts the day count from Validation's booking-window variants" do
      assert BookingErrorMessage.message("Cannot book more than 90 days in advance") =~
               "90 days"

      assert BookingErrorMessage.message("Booking cannot be more than 365 days in advance") =~
               "365 days"
    end
  end

  describe "message/1 with unrecognised binary reasons" do
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
