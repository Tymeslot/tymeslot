defmodule Tymeslot.Bookings.Orchestrator do
  @moduledoc """
  Orchestrates the booking flow for the web layer.

  This module acts as a bridge between the web layer (LiveViews) and the domain layer,
  delegating business logic to appropriate domain modules.
  """

  alias Tymeslot.Bookings.{Create, Validation}
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

  Returns {:ok, meeting} or {:error, reason}
  """
  @spec submit_booking(booking_submission_params(), keyword()) :: {:ok, term()} | {:error, term()}
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
      {:ok, meeting} ->
        {:ok, meeting}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _reason} ->
        {:error, "Failed to process booking. Please try again."}
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
          {:ok, Ecto.Schema.t()} | {:error, String.t()}
  def get_meeting_for_reschedule(meeting_uid, organizer_user_id)
      when is_integer(organizer_user_id) do
    with {:ok, meeting} <-
           MeetingQueries.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id),
         {:ok, meeting} <- Validation.validate_meeting_for_reschedule(meeting) do
      {:ok, meeting}
    else
      {:error, :not_found} -> {:error, "Meeting not found"}
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
    do: {:error, "Meeting not found"}

  defp reschedule_meeting(meeting_uid, meeting_params, sanitized_data, organizer_user_id)
       when is_integer(organizer_user_id) do
    Meetings.reschedule_meeting(meeting_uid, meeting_params, sanitized_data, organizer_user_id)
  end
end
