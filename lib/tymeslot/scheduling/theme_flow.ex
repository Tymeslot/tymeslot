defmodule Tymeslot.Scheduling.ThemeFlow do
  @moduledoc """
  Shared scheduling helpers for theme flows.

  This module keeps domain logic in the core so LiveViews only orchestrate UI state.
  """

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Demo
  alias Tymeslot.Meetings
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

  @doc """
  Pre-fills the booking form for a seat reschedule from the participant's
  own data. The token scopes the lookup, so no organizer id is needed and
  no other booker's PII can be pre-filled.
  """
  @spec build_seat_booking_form_data(String.t() | nil) :: %{String.t() => String.t()}
  def build_seat_booking_form_data(nil), do: default_booking_form_data()

  def build_seat_booking_form_data(seat_token) when is_binary(seat_token) do
    case Meetings.get_participant_by_token(seat_token) do
      {:ok, %{cancelled_at: nil} = participant} ->
        %{
          "name" => participant.name,
          "email" => participant.email,
          "message" => participant.message || ""
        }

      _cancelled_or_missing ->
        default_booking_form_data()
    end
  end

  @doc """
  True when a seat-management token still identifies a live seat.

  The token rides in the picker URL as `reschedule_seat_token`, which browser
  history keeps long after the seat has been moved or given up. A dead token
  left in the assigns routes every later submission through the seat-move
  path, where it can only fail — so the booking page checks it once and
  forgets it if it is spent, letting the visitor simply book afresh.
  """
  @spec live_seat_token?(String.t() | nil) :: boolean()
  def live_seat_token?(seat_token) when is_binary(seat_token) do
    match?({:ok, _seat}, Meetings.fetch_live_seat(seat_token))
  end

  def live_seat_token?(_missing), do: false
end
