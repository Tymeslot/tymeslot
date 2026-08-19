defmodule TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage do
  @moduledoc """
  Renders `Tymeslot.Bookings.Errors.classified_error/0` atoms (and legacy
  Policy/Validation binary strings) into user-facing flash copy — display
  copy is a presentation-layer concern, not baked into the domain contract.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders a booking error reason to user-facing flash text.

  Unknown atoms and unmapped binaries fall back to a generic message
  rather than leaking internals.
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

  # Legacy string errors shared with the cancel/reschedule/create-ad-hoc flow
  # (`Policy.can_reschedule_meeting?/1`, `Validation`, `CreateAdHoc`), which
  # still return binaries directly — atomizing those is a future pass, out of
  # scope here. Translated via a fixed mapping (exact strings, plus a couple
  # of regexes for the messages `Validation` builds with an interpolated
  # day/hour count) rather than passed through, so a binary the mapping
  # doesn't recognise falls back to the generic message instead of leaking
  # internal English text onto the public booking page.
  def message(reason) when is_binary(reason) do
    legacy_message(reason) ||
      dgettext("booking", "Failed to create appointment. Please try again.")
  end

  def message(_other) do
    dgettext("booking", "Failed to create appointment. Please try again.")
  end

  @notice_hours_regex ~r/^Booking requires at least (\d+) hours (?:in advance|advance notice)$/
  @window_days_regex ~r/^(?:Cannot book more than|Booking cannot be more than) (\d+) days in advance$/

  @spec legacy_message(String.t()) :: String.t() | nil
  # Both variants reuse the msgid `localization_helpers.ex` already defines
  # (and every locale already translates) for the same underlying problem,
  # rather than adding two new near-duplicate, untranslated strings.
  defp legacy_message("Invalid date or time format"),
    do: dgettext("booking", "Invalid date/time")

  defp legacy_message("Invalid date format"),
    do: dgettext("booking", "Invalid date/time")

  defp legacy_message("Meeting is already cancelled"),
    do: dgettext("booking", "Meeting is already cancelled")

  defp legacy_message("Cannot cancel a completed meeting"),
    do: dgettext("booking", "Cannot cancel a completed meeting")

  defp legacy_message("Cannot cancel a meeting that has already started"),
    do: dgettext("booking", "Cannot cancel a meeting that has already started")

  defp legacy_message("Cannot cancel a meeting that has already occurred"),
    do: dgettext("booking", "Cannot cancel a meeting that has already occurred")

  defp legacy_message("Cannot reschedule a cancelled meeting"),
    do: dgettext("booking", "Cannot reschedule a cancelled meeting")

  defp legacy_message("Cannot reschedule a completed meeting"),
    do: dgettext("booking", "Cannot reschedule a completed meeting")

  defp legacy_message("Cannot reschedule a meeting that has already started"),
    do: dgettext("booking", "Cannot reschedule a meeting that has already started")

  defp legacy_message("Cannot reschedule a meeting that has already occurred"),
    do: dgettext("booking", "Cannot reschedule a meeting that has already occurred")

  defp legacy_message("Booking time must be in the future"),
    do: dgettext("booking", "Booking time must be in the future")

  defp legacy_message("Attendee email is required"),
    do: dgettext("booking", "Attendee email is required")

  defp legacy_message("Attendee name is required"),
    do: dgettext("booking", "Attendee name is required")

  defp legacy_message("End time must be after start time"),
    do: dgettext("booking", "End time must be after start time")

  defp legacy_message("Failed to create meeting"),
    do: dgettext("booking", "Failed to create meeting")

  defp legacy_message("Failed to update meeting status"),
    do: dgettext("booking", "Failed to update meeting status")

  defp legacy_message("The guest email must differ from your own address"),
    do: dgettext("booking", "The guest email must differ from your own address")

  defp legacy_message("Title is required"),
    do: dgettext("booking", "Title is required")

  defp legacy_message(reason) do
    cond do
      match = Regex.run(@notice_hours_regex, reason) ->
        [_full, hours] = match
        dgettext("booking", "Booking requires at least %{hours} hours in advance", hours: hours)

      match = Regex.run(@window_days_regex, reason) ->
        [_full, days] = match
        dgettext("booking", "You cannot book more than %{days} days in advance", days: days)

      true ->
        nil
    end
  end
end
