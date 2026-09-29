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

  alias Tymeslot.Infrastructure.ErrorTracking

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

  # Table rather than a clause ladder: every entry is the same behaviour over
  # varying data, so the mapping is the whole content. `:availability_unverifiable`
  # collapses to `:slot_taken` because the organiser's full busy set could not
  # be read and so the slot cannot be proven free — the booker gets the same
  # "pick another slot" outcome as a genuine clash, and the distinction survives
  # in the logs rather than the copy. `:time_conflict` and `:slot_unavailable`
  # both describe the same lost-race outcome and collapse to `:slot_taken`;
  # `:host_not_found`/`:host_missing` and `:meeting_type_not_found`/
  # `:meeting_type_missing` are likewise distinct upstream reasons that share
  # one user-facing meaning, so they collapse to a single atom each.
  # `ScheduleCheck`'s own reasons (`:slot_not_offered`,
  # `:slot_availability_unverifiable`) are deliberately absent: they are
  # classified once, by `classify_schedule_check_reason/1` below, which
  # `classify_error/1` falls back to for any other atom.
  @error_classifications %{
    meeting_type_inactive: :meeting_type_inactive,
    meeting_type_not_found: :meeting_type_not_found,
    meeting_type_missing: :meeting_type_not_found,
    time_conflict: :slot_taken,
    slot_unavailable: :slot_taken,
    availability_unverifiable: :slot_taken,
    booking_limit_reached: :booking_limit_reached,
    organizer_required: :organizer_required,
    validation_error: :booking_failed,
    payments_unavailable: :payments_unavailable,
    host_not_found: :host_not_found,
    host_missing: :host_not_found
  }

  # `Tymeslot.Bookings.ScheduleCheck` is shared by `Create` and `Reschedule`,
  # so its failure reasons are classified once, here, rather than in a table
  # per caller: a reason ScheduleCheck grows in the future is then picked up
  # by both without either module changing.
  @schedule_check_classifications %{
    slot_not_offered: :slot_taken,
    slot_availability_unverifiable: :slot_taken
  }

  @doc """
  Classifies every failure reason into a semantic atom rather than a display
  string, so callers can dispatch on the error's identity (e.g. bounce the
  booker back to the schedule step on `:slot_taken`) without depending on
  copy text. The web layer owns rendering these atoms to user-facing
  messages. Reasons that already arrive as arbitrary changeset/validation
  text pass through unchanged (`is_binary/1` clause).

  Shared by `Tymeslot.Bookings.Create` and `Tymeslot.Bookings.CreateGroup`.
  """
  @spec classify_error(term()) :: classified_error() | String.t()
  def classify_error(reason) when is_map_key(@error_classifications, reason),
    do: Map.fetch!(@error_classifications, reason)

  def classify_error({:custom_field_errors, _errors}), do: :custom_field_errors
  def classify_error({:checkout_failed, _reason}), do: :checkout_failed

  def classify_error(reason) when is_atom(reason),
    do: classify_schedule_check_reason(reason) || :booking_failed

  def classify_error(reason) when is_binary(reason), do: reason
  def classify_error(_other), do: :booking_failed

  # Once validation has passed, the only failures creating the meeting is
  # expected to meet are the ones the classification names: a lost race, a
  # limit reached, a changeset refusing the booker's input. Anything that
  # classifies as nothing better than `:booking_failed` (a guest row the
  # database refused after sanitising, a calendar job Oban would not insert,
  # a reason nobody wrote a clause for) is a bug or an outage, and is
  # recorded. Two reasons that also classify as `:booking_failed` are not:
  # `:validation_error` is the booker's input refused, and `:database_error`
  # was recorded, with its exception, by `Meetings.Scheduling` where it was
  # raised.
  @not_reported [:validation_error, :database_error]

  @doc """
  Classifies a failure from creating a booking's meeting, as
  `classify_error/1` does, and records in error tracking any reason that
  classifies as nothing better than `:booking_failed` (see the comment
  above `@not_reported`).

  Shared by `Tymeslot.Bookings.Create` and `Tymeslot.Bookings.CreateGroup`.
  """
  @spec classify_creation_error(term(), map()) :: classified_error() | String.t()
  def classify_creation_error(reason, booking_data) do
    case classify_error(reason) do
      :booking_failed when reason not in @not_reported ->
        :ok =
          ErrorTracking.report_error(reason, nil, %{
            organizer_user_id: booking_data.organizer_user_id,
            meeting_type_id: booking_data.meeting_type_id
          })

        :booking_failed

      classified ->
        classified
    end
  end

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
