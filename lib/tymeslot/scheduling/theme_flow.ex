defmodule Tymeslot.Scheduling.ThemeFlow do
  @moduledoc """
  Shared scheduling helpers for theme flows.

  This module keeps domain logic in the core so LiveViews only orchestrate UI state.
  """

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Demo
  alias Tymeslot.MeetingTypes

  @spec resolve_meeting_type_for_duration(pos_integer(), String.t()) :: map() | nil
  def resolve_meeting_type_for_duration(user_id, duration) do
    duration_slug = MeetingTypes.normalize_duration_slug(duration)
    Demo.find_by_duration_string(user_id, duration_slug)
  end

  @spec resolve_meeting_type_for_slug(pos_integer(), String.t()) :: map() | nil
  def resolve_meeting_type_for_slug(user_id, slug) do
    Demo.find_by_slug(user_id, slug)
  end

  @doc """
  The meeting type a reschedule is already committed to.

  Matching by duration is right while a visitor is still choosing what to book,
  but a reschedule is not a choice: the rules enforced on submit come from the
  original meeting's type, and two types sharing a duration may sit on
  different availability schedules. Resolving by duration could therefore offer
  slots from one schedule and reject the booking against another's.

  Returns `nil` when this is not a reschedule, when the meeting is not the
  organiser's, or when it predates meeting types; the caller then falls back to
  the duration match.
  """
  @spec resolve_meeting_type_for_reschedule(String.t() | nil, integer() | nil) :: map() | nil
  def resolve_meeting_type_for_reschedule(meeting_uid, organizer_user_id)
      when is_binary(meeting_uid) and is_integer(organizer_user_id) do
    with {:ok, %{meeting_type_id: id}} when is_integer(id) <-
           Orchestrator.get_meeting_for_reschedule(meeting_uid, organizer_user_id),
         %{} = meeting_type <- MeetingTypes.get_meeting_type(id, organizer_user_id) do
      meeting_type
    else
      _not_resolvable -> nil
    end
  end

  def resolve_meeting_type_for_reschedule(_meeting_uid, _organizer_user_id), do: nil

  @spec build_booking_form_data(String.t() | nil, integer() | nil) :: map()
  def build_booking_form_data(reschedule_uid, organizer_user_id \\ nil)

  def build_booking_form_data(nil, _organizer_user_id), do: default_booking_form_data()

  def build_booking_form_data(_reschedule_uid, nil), do: default_booking_form_data()

  def build_booking_form_data(reschedule_uid, organizer_user_id)
      when is_binary(reschedule_uid) and is_integer(organizer_user_id) do
    case Orchestrator.get_meeting_for_reschedule(reschedule_uid, organizer_user_id) do
      {:ok, meeting} ->
        %{
          "name" => meeting.attendee_name,
          "email" => meeting.attendee_email,
          "message" => meeting.attendee_message || ""
        }

      _error ->
        default_booking_form_data()
    end
  end

  defp default_booking_form_data do
    %{"name" => "", "email" => "", "message" => ""}
  end
end
