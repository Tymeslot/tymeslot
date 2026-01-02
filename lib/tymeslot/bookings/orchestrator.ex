defmodule Tymeslot.Bookings.Orchestrator do
  @moduledoc """
  Orchestrates the booking flow for the web layer.

  This module acts as a bridge between the web layer (LiveViews) and the domain layer,
  delegating business logic to appropriate domain modules.
  """

  alias Tymeslot.Bookings.{Create, Validation}
  alias Tymeslot.Meetings
  alias Tymeslot.Security.FormValidation

  @doc """
  Orchestrates the complete booking submission flow including:
  - Form validation
  - Rate limiting (if client IP provided)
  - Meeting creation or rescheduling

  Returns {:ok, meeting} or {:error, reason}
  """
  @spec submit_booking(map(), keyword()) :: {:ok, term()} | {:error, term()}
  def submit_booking(params, opts \\ []) do
    %{
      form_data: form_data,
      meeting_params: meeting_params,
      is_rescheduling: is_rescheduling,
      reschedule_uid: reschedule_uid
    } = normalize_params(params, opts)

    with {:ok, sanitized_data} <- validate_form(form_data),
         {:ok, meeting} <-
           create_or_reschedule_meeting(
             is_rescheduling,
             reschedule_uid,
             meeting_params,
             sanitized_data
           ) do
      {:ok, meeting}
    else
      {:error, errors} when is_list(errors) ->
        {:error, errors}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, "Failed to process booking. Please try again."}
    end
  end

  @doc """
  Validates booking time against availability.
  Used for pre-submission validation in the UI.
  """
  @spec validate_booking_time(String.t(), String.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, String.t()}
  def validate_booking_time(date_str, time_str, timezone) do
    Validation.validate_booking_time_from_strings(date_str, time_str, timezone)
  end

  @doc """
  Gets a meeting for rescheduling validation.
  """
  @spec get_meeting_for_reschedule(String.t()) :: {:ok, term()} | {:error, String.t()}
  def get_meeting_for_reschedule(meeting_uid) do
    Validation.get_meeting_for_reschedule(meeting_uid)
  end

  # Private functions

  defp normalize_params(params, opts) do
    %{
      form_data: Map.get(params, :form_data, %{}),
      meeting_params: Map.get(params, :meeting_params, %{}),
      is_rescheduling: Keyword.get(opts, :is_rescheduling, false),
      reschedule_uid: Keyword.get(opts, :reschedule_uid)
    }
  end

  defp validate_form(form_data) do
    case FormValidation.validate_booking_form(form_data) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, errors} -> {:error, errors}
    end
  end

  defp create_or_reschedule_meeting(
         true,
         reschedule_uid,
         meeting_params,
         sanitized_data
       ) do
    # Rescheduling flow
    reschedule_meeting(reschedule_uid, meeting_params, sanitized_data)
  end

  defp create_or_reschedule_meeting(
         false,
         _reschedule_uid,
         meeting_params,
         sanitized_data
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

  defp reschedule_meeting(meeting_uid, meeting_params, sanitized_data) do
    Meetings.reschedule_meeting(meeting_uid, meeting_params, sanitized_data)
  end
end
