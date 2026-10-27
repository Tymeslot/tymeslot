defmodule TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage do
  @moduledoc """
  Renders `Tymeslot.Bookings.Errors.classified_error/0` reasons, the
  `Tymeslot.Bookings.Policy` and `Tymeslot.Bookings.Validation` refusals
  among them, into user-facing flash copy — display copy is a
  presentation-layer concern, not baked into the domain contract.
  A taken time can be worded by the rendering theme's voice (`voiced/2`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Voice

  @doc """
  Renders a booking error reason to user-facing flash text.

  Unknown reasons fall back to a generic message rather than leaking
  internals.
  """
  @spec message(term()) :: String.t()
  def message(:slot_taken) do
    dgettext(
      "booking_errors",
      "This time slot is no longer available. Please select a different time."
    )
  end

  def message(:availability_unverifiable) do
    dgettext(
      "booking_errors",
      "We couldn't check the host's calendar right now. Please try again in a few minutes."
    )
  end

  def message(:booking_limit_reached) do
    dgettext(
      "booking_errors",
      "The host is no longer accepting bookings for this period. Please pick a different day."
    )
  end

  def message(:meeting_type_inactive) do
    dgettext(
      "booking_errors",
      "This meeting type is no longer available. Please refresh the page."
    )
  end

  def message(:meeting_type_not_found) do
    dgettext(
      "booking_errors",
      "This meeting type is no longer available. Please go back and select another."
    )
  end

  def message(:organizer_required) do
    dgettext("booking_errors", "Organiser is required for booking")
  end

  def message(:booking_failed) do
    dgettext("booking_errors", "Failed to save meeting to database")
  end

  def message(:payments_unavailable) do
    dgettext(
      "booking_errors",
      "Payments are not available for this booking. Please contact the host."
    )
  end

  def message(:host_not_found) do
    dgettext("booking_errors", "Host could not be found. Please refresh and try again.")
  end

  def message(:custom_field_errors) do
    dgettext("booking_errors", "Please fill in all required fields before submitting.")
  end

  def message(:checkout_failed) do
    dgettext("booking_errors", "We couldn't start the payment process. Please try again.")
  end

  def message(:failed_to_update_meeting) do
    dgettext("booking_errors", "Failed to process booking. Please try again.")
  end

  def message(:meeting_not_found) do
    dgettext("booking_errors", "This meeting could not be found. Please refresh and try again.")
  end

  def message(:already_booked) do
    dgettext(
      "booking_errors",
      "You already have a spot at this time. Check your email for your booking confirmation."
    )
  end

  def message(:already_cancelled) do
    dgettext("booking_errors", "This booking has already been cancelled or moved.")
  end

  def message(:group_meeting_not_reschedulable) do
    dgettext(
      "booking_errors",
      "This is a group booking, so each participant moves their own spot from their confirmation email."
    )
  end

  def message(:managed_by_host) do
    dgettext(
      "booking_errors",
      "This meeting was arranged by a poll, so only its host can move it. If the new time doesn't suit you, reply to your invitation."
    )
  end

  def message(:seat_not_movable) do
    dgettext(
      "booking_errors",
      "This spot can no longer be moved. Cancel it and book a new time instead, or contact the host."
    )
  end

  def message(:seat_time_unchanged) do
    dgettext(
      "booking_errors",
      "This is your current time. Pick a different time to move your spot."
    )
  end

  # Step-requirement refusals: the booker has not chosen enough yet to move on.
  # `Availability.Calculate` and `MeetingTypes.Duration` used to return this
  # copy themselves, in English, straight into a flash on a public multi-locale
  # page.
  def message(:duration_required) do
    dgettext("booking_errors", "Please select a meeting duration")
  end

  def message(:duration_invalid) do
    dgettext("booking_errors", "Invalid meeting duration selected")
  end

  def message(:date_required) do
    dgettext("booking_errors", "Please select a date")
  end

  def message(:time_required) do
    dgettext("booking_errors", "Please select a time")
  end

  def message(:selection_required) do
    dgettext("booking_errors", "Please select a date and time")
  end

  # Refusals from the booking rules (`Policy`, `Validation`, `CreateAdHoc`).
  def message({:not_cancellable, :completed}),
    do: dgettext("booking_errors", "Cannot cancel a completed meeting")

  def message({:not_cancellable, :expired}),
    do: dgettext("booking_errors", "Cannot cancel an expired meeting")

  def message({:not_cancellable, :started}),
    do: dgettext("booking_errors", "Cannot cancel a meeting that has already started")

  def message({:not_cancellable, :past}),
    do: dgettext("booking_errors", "Cannot cancel a meeting that has already occurred")

  def message({:not_reschedulable, :cancelled}),
    do: dgettext("booking_errors", "Cannot reschedule a cancelled meeting")

  def message({:not_reschedulable, :completed}),
    do: dgettext("booking_errors", "Cannot reschedule a completed meeting")

  def message({:not_reschedulable, :expired}),
    do: dgettext("booking_errors", "Cannot reschedule an expired meeting")

  def message({:not_reschedulable, :started}),
    do: dgettext("booking_errors", "Cannot reschedule a meeting that has already started")

  def message({:not_reschedulable, :past}),
    do: dgettext("booking_errors", "Cannot reschedule a meeting that has already occurred")

  def message({:not_reschedulable, :awaiting_approval}),
    do:
      dgettext("booking_errors", "Cannot request a reschedule while the booking awaits approval")

  def message({:not_reschedulable, :planned}),
    do:
      dgettext(
        "booking_errors",
        "A fixed date is moved from its meeting type, together with everyone booked on it"
      )

  # Reuses the msgid `localization_helpers.ex` already defines (and every
  # locale already translates) for the same problem.
  def message(:invalid_datetime), do: dgettext("booking_errors", "Invalid date/time")

  def message(:in_past), do: dgettext("booking_errors", "Booking time must be in the future")

  def message({:too_soon, hours}),
    do:
      dgettext("booking_errors", "Booking requires at least %{hours} hours in advance",
        hours: hours
      )

  def message({:too_far_ahead, days}),
    do:
      dgettext("booking_errors", "You cannot book more than %{days} days in advance", days: days)

  def message(:title_required), do: dgettext("booking_errors", "Title is required")

  def message(:attendee_name_required),
    do: dgettext("booking_errors", "Attendee name is required")

  def message(:attendee_email_required),
    do: dgettext("booking_errors", "Attendee email is required")

  def message(:attendee_is_organizer),
    do: dgettext("booking_errors", "The guest email must differ from your own address")

  def message(:end_before_start),
    do: dgettext("booking_errors", "End time must be after start time")

  def message(:invalid_reminders),
    do: dgettext("booking_errors", "The reminders for this meeting are not valid")

  def message(:meeting_creation_failed),
    do: dgettext("booking_errors", "Failed to create meeting")

  def message(_other), do: unrecognised_message()

  @doc """
  Like `message/1`, but a reason it does not recognise renders `fallback`
  instead of the booking-specific generic message, for callers outside the
  booking submission (cancelling, rescheduling) whose generic failure reads
  differently.
  """
  @spec message(term(), String.t()) :: String.t()
  def message(reason, fallback) do
    unrecognised = unrecognised_message()

    case message(reason) do
      ^unrecognised -> fallback
      rendered -> rendered
    end
  end

  @doc """
  `message/1`, in the voice of the theme with id `theme_id` where that voice
  words the line. Only a taken time (`:slot_taken`) is a voice line; every
  other reason, a theme without a voice and an unknown or missing id keep
  `message/1`'s wording.
  """
  @spec voiced(atom() | String.t(), String.t() | nil) :: String.t()
  def voiced(:slot_taken, theme_id),
    do: Voice.line(voice(theme_id), :slot_taken, %{}, fn -> message(:slot_taken) end)

  def voiced(reason, _theme_id), do: message(reason)

  defp voice(theme_id) when is_binary(theme_id) do
    case Catalog.id_to_key(theme_id) do
      {:ok, key} -> Voice.of(key)
      {:error, _unknown} -> nil
    end
  end

  defp voice(_no_theme), do: nil

  defp unrecognised_message do
    dgettext("booking_errors", "Failed to create meeting. Please try again.")
  end
end
