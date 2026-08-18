defmodule TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage do
  @moduledoc """
  Renders `Tymeslot.Bookings.Errors.classified_error/0` atoms (and legacy
  Policy/Validation binary strings) into user-facing flash copy — display
  copy is a presentation-layer concern, not baked into the domain contract.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders a booking error reason to user-facing flash text.

  Unknown atoms and long binaries fall back to a generic message rather
  than leaking internals.
  """
  @spec message(atom() | String.t()) :: String.t()
  def message(:slot_taken) do
    dgettext(
      "booking",
      "This time slot is no longer available. Please select a different time."
    )
  end

  def message(:booking_limit_reached) do
    dgettext(
      "booking",
      "The host is no longer accepting bookings for this period. Please pick a different day."
    )
  end

  def message(:meeting_type_inactive) do
    dgettext("booking", "This meeting type is no longer available. Please refresh the page.")
  end

  def message(:meeting_type_not_found) do
    dgettext(
      "booking",
      "This meeting type is no longer available. Please go back and select another."
    )
  end

  def message(:organizer_required) do
    dgettext("booking", "Organizer is required for booking")
  end

  def message(:booking_failed) do
    dgettext("booking", "Failed to save meeting to database")
  end

  def message(:payments_unavailable) do
    dgettext(
      "booking",
      "Payments are not available for this booking. Please contact the host."
    )
  end

  def message(:host_not_found) do
    dgettext("booking", "Host could not be found. Please refresh and try again.")
  end

  def message(:custom_field_errors) do
    dgettext("booking", "Please fill in all required fields before submitting.")
  end

  def message(:checkout_failed) do
    dgettext("booking", "We couldn't start the payment process. Please try again.")
  end

  def message(:failed_to_update_meeting) do
    dgettext("booking", "Failed to process booking. Please try again.")
  end

  def message(:meeting_not_found) do
    dgettext("booking", "This meeting could not be found. Please refresh and try again.")
  end

  # Step-requirement refusals: the booker has not chosen enough yet to move on.
  # `Availability.Calculate` and `MeetingTypes.Duration` used to return this
  # copy themselves, in English, straight into a flash on a public multi-locale
  # page.
  def message(:duration_required) do
    dgettext("booking", "Please select a meeting duration")
  end

  def message(:duration_invalid) do
    dgettext("booking", "Invalid meeting duration selected")
  end

  def message(:date_required) do
    dgettext("booking", "Please select a date")
  end

  def message(:time_required) do
    dgettext("booking", "Please select a time")
  end

  def message(:selection_required) do
    dgettext("booking", "Please select a date and time")
  end

  # Intentional passthrough, not dead code: reschedule shares its domain
  # validation with cancel (`Policy.can_reschedule_meeting?/1`,
  # `Validation`), which still returns binaries directly — atomizing
  # those is a future pass, out of scope here.
  def message(reason) when is_binary(reason) and byte_size(reason) < 100, do: reason

  def message(_other) do
    dgettext("booking", "Failed to create appointment. Please try again.")
  end
end
