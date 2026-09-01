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

  # `Tymeslot.Bookings.ScheduleCheck` is shared by `Create` and `Reschedule`,
  # so its failure reasons are classified once, here, rather than in a table
  # per caller: a reason ScheduleCheck grows in the future is then picked up
  # by both without either module changing.
  @schedule_check_classifications %{
    slot_not_offered: :slot_taken,
    slot_availability_unverifiable: :slot_taken
  }

  @doc """
  Classifies a `Tymeslot.Bookings.ScheduleCheck.validate_slot_on_schedule/6`
  failure reason into the shared vocabulary.

  Returns `nil` for any reason ScheduleCheck does not produce, so a caller can
  fall back to passing the reason through unchanged.
  """
  @spec classify_schedule_check_reason(atom()) :: classified_error() | nil
  def classify_schedule_check_reason(reason)
      when is_map_key(@schedule_check_classifications, reason),
      do: Map.fetch!(@schedule_check_classifications, reason)

  def classify_schedule_check_reason(_reason), do: nil
end
