defmodule Tymeslot.Bookings.Orchestrator do
  @moduledoc """
  Orchestrates the booking flow for the web layer.

  This module acts as a bridge between the web layer (LiveViews) and the domain layer,
  delegating business logic to appropriate domain modules.
  """

  alias Tymeslot.Bookings.{Create, Errors, Validation}
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries

  @typedoc "Parameters for `submit_booking/2`."
  @type booking_submission_params :: %{
          optional(:form_data) => %{String.t() => term()},
          optional(:meeting_params) => map()
        }

  @doc """
  Orchestrates the complete booking submission flow including:
  - Form validation
  - Rate limiting (if client IP provided)
  - Meeting creation or rescheduling

  Returns:
    * `{:ok, meeting}` for free bookings (confirmed)
    * `{:ok, :payment_required, %{meeting: meeting, checkout_url: url}}` when
      the meeting type requires payment — caller should redirect the
      attendee to the Stripe Checkout URL
    * `{:error, reason}` on validation or persistence failure, where
      `reason` is either a semantic atom classified by the domain layer
      (`Tymeslot.Bookings.Errors.classified_error/0`, e.g. `:slot_taken`,
      `:meeting_type_inactive`, `:meeting_not_found`) or an arbitrary
      changeset/validation string. Atoms and binaries are passed through
      unchanged — this module never manufactures display copy, that is the
      web layer's job. Any other shape collapses to the generic
      `:booking_failed` atom.
  """
  @spec submit_booking(booking_submission_params(), keyword()) ::
          {:ok, term()}
          | {:ok, :payment_required, %{meeting: map(), checkout_url: String.t()}}
          | {:error, Errors.classified_error() | String.t()}
  def submit_booking(params, opts \\ []) do
    %{
      form_data: form_data,
      meeting_params: meeting_params,
      is_rescheduling: is_rescheduling,
      reschedule_uid: reschedule_uid,
      organizer_user_id: organizer_user_id
    } = normalize_params(params, opts)

    case create_or_reschedule_meeting(
           is_rescheduling,
           reschedule_uid,
           meeting_params,
           form_data,
           organizer_user_id
         ) do
      {:ok, :payment_required, _payload} = payment_tuple ->
        payment_tuple

      {:ok, meeting} ->
        {:ok, meeting}

      {:error, reason} when is_atom(reason) or is_binary(reason) ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :booking_failed}
    end
  end

  @doc """
  Validates booking time against availability.
  Used for pre-submission validation in the UI.
  """
  @spec validate_booking_time(String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def validate_booking_time(date_str, time_str, timezone) do
    Validation.validate_booking_time_from_strings(date_str, time_str, timezone)
  end

  @doc """
  Fetches a meeting by UID and validates it is eligible for rescheduling.

  The `organizer_user_id` is required. The lookup is scoped to that owner,
  preventing IDOR pre-fill of attendee PII from the public booking form.
  """
  @spec get_meeting_for_reschedule(String.t(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, Errors.classified_error() | String.t()}
  def get_meeting_for_reschedule(meeting_uid, organizer_user_id)
      when is_integer(organizer_user_id) do
    with {:ok, meeting} <-
           MeetingQueries.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id),
         {:ok, meeting} <- Validation.validate_meeting_for_reschedule(meeting) do
      {:ok, meeting}
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Private functions

  defp normalize_params(params, opts) do
    %{
      form_data: Map.get(params, :form_data, %{}),
      meeting_params: Map.get(params, :meeting_params, %{}),
      is_rescheduling: Keyword.get(opts, :is_rescheduling, false),
      reschedule_uid: Keyword.get(opts, :reschedule_uid),
      organizer_user_id: Keyword.get(opts, :organizer_user_id)
    }
  end

  defp create_or_reschedule_meeting(
         true,
         reschedule_uid,
         meeting_params,
         sanitized_data,
         organizer_user_id
       ) do
    # Rescheduling flow
    reschedule_meeting(reschedule_uid, meeting_params, sanitized_data, organizer_user_id)
  end

  defp create_or_reschedule_meeting(
         false,
         _reschedule_uid,
         meeting_params,
         sanitized_data,
         _organizer_user_id
       ) do
    # New booking flow
    create_meeting(meeting_params, sanitized_data)
  end

  defp create_meeting(meeting_params, sanitized_data) do
    # Use the appropriate creation method based on context
    if meeting_params[:with_video_room] do
      Create.execute_with_video_room(meeting_params, sanitized_data)
    else
      Create.execute(meeting_params, sanitized_data)
    end
  end

  defp reschedule_meeting(_meeting_uid, _meeting_params, _sanitized_data, nil),
    do: {:error, :meeting_not_found}

  defp reschedule_meeting(meeting_uid, meeting_params, sanitized_data, organizer_user_id)
       when is_integer(organizer_user_id) do
    Meetings.reschedule_meeting(meeting_uid, meeting_params, sanitized_data, organizer_user_id)
  end
end
