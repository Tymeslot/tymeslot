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
  def message(reason) do
    case reason do
      :slot_taken ->
        dgettext(
          "booking",
          "This time slot is no longer available. Please select a different time."
        )

      :meeting_type_inactive ->
        dgettext("booking", "This meeting type is no longer available. Please refresh the page.")

      :meeting_type_not_found ->
        dgettext(
          "booking",
          "This meeting type is no longer available. Please go back and select another."
        )

      :organizer_required ->
        dgettext("booking", "Organizer is required for booking")

      :booking_failed ->
        dgettext("booking", "Failed to save meeting to database")

      :payments_unavailable ->
        dgettext(
          "booking",
          "Payments are not available for this booking. Please contact the host."
        )

      :host_not_found ->
        dgettext("booking", "Host could not be found. Please refresh and try again.")

      :custom_field_errors ->
        dgettext("booking", "Please fill in all required fields before submitting.")

      :checkout_failed ->
        dgettext("booking", "We couldn't start the payment process. Please try again.")

      :failed_to_update_meeting ->
        dgettext("booking", "Failed to process booking. Please try again.")

      :meeting_not_found ->
        dgettext("booking", "This meeting could not be found. Please refresh and try again.")

      # Intentional passthrough, not dead code: reschedule shares its domain
      # validation with cancel (`Policy.can_reschedule_meeting?/1`,
      # `Validation`), which still returns binaries directly — atomizing
      # those is a future pass, out of scope here.
      reason when is_binary(reason) ->
        if String.length(reason) < 100,
          do: reason,
          else: dgettext("booking", "Failed to create appointment. Please try again.")

      _other ->
        dgettext("booking", "Failed to create appointment. Please try again.")
    end
  end
end
