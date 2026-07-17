defmodule Tymeslot.Bookings.Errors do
  @moduledoc """
  Shared semantic error vocabulary for the booking domain.

  `Tymeslot.Bookings.Create` and `Tymeslot.Bookings.Reschedule` classify
  every known failure reason into one of these atoms rather than a display
  string, so callers can dispatch on an error's identity (e.g. bounce the
  booker back to the schedule step on `:slot_taken`) without depending on
  copy text. Rendering an atom to user-facing copy is entirely the web
  layer's responsibility — see
  `TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage`.

  Reasons that don't yet have a semantic atom (arbitrary changeset/validation
  text from `Tymeslot.Bookings.Policy` and `Tymeslot.Bookings.Validation`,
  shared with the cancel flow) still arrive as plain binaries and are out of
  scope for this vocabulary.
  """

  @typedoc "Semantic booking error atoms shared across the booking domain."
  @type classified_error ::
          :meeting_type_inactive
          | :meeting_type_not_found
          | :slot_taken
          | :booking_limit_reached
          | :organizer_required
          | :booking_failed
          | :payments_unavailable
          | :host_not_found
          | :custom_field_errors
          | :checkout_failed
          | :meeting_not_found
          | :failed_to_update_meeting
end
