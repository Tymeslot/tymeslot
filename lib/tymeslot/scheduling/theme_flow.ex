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
    MeetingTypes.find_by_slug(user_id, slug)
  end

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
