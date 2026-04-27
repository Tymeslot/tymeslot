defmodule Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver do
  @moduledoc """
  Resolves which calendar integration owns a booking, given a `Meeting`,
  `MeetingType`, `{integration_id, user_id}` tuple, or bare user id.

  The resolver implements a fallback chain:

  1. If the explicit context names a still-active integration that the user
     owns, that integration is returned (with `default_booking_calendar_id`
     overridden by the context's stored value where applicable).
  2. Otherwise the user's primary calendar integration is used.
  3. If the primary has no booking calendar configured, the first
     integration with a booking calendar is used.
  4. Finally, any integration is used.
  """

  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @type integration :: map()
  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()

  @doc """
  Resolves a booking integration from the given context. Returns the
  integration on success, or `nil` if no usable integration exists for the
  user.
  """
  @spec resolve(
          nil
          | user_id()
          | {integration_id(), user_id()}
          | MeetingSchema.t()
          | MeetingTypeSchema.t()
        ) :: integration() | nil
  def resolve(nil), do: nil

  def resolve({integration_id, user_id})
      when is_integer(integration_id) and is_integer(user_id) do
    case CalendarManagement.fetch_integration_for_user(integration_id, user_id) do
      {:ok, integration} when integration.is_active -> integration
      _not_found_or_inactive -> resolve(user_id)
    end
  end

  def resolve(%MeetingSchema{} = meeting) do
    cond do
      is_integer(meeting.calendar_integration_id) ->
        case CalendarManagement.fetch_integration_for_user(
               meeting.calendar_integration_id,
               meeting.organizer_user_id
             ) do
          {:ok, integration} when integration.is_active ->
            %{integration | default_booking_calendar_id: meeting.calendar_path}

          _not_found_or_inactive ->
            resolve(meeting.organizer_user_id)
        end

      is_integer(meeting.organizer_user_id) ->
        resolve(meeting.organizer_user_id)

      true ->
        nil
    end
  end

  def resolve(%MeetingTypeSchema{} = meeting_type) do
    cond do
      is_integer(meeting_type.calendar_integration_id) ->
        case CalendarManagement.fetch_integration_for_user(
               meeting_type.calendar_integration_id,
               meeting_type.user_id
             ) do
          {:ok, integration} when integration.is_active ->
            %{integration | default_booking_calendar_id: meeting_type.target_calendar_id}

          _not_found_or_inactive ->
            resolve(meeting_type.user_id)
        end

      is_integer(meeting_type.user_id) ->
        resolve(meeting_type.user_id)

      true ->
        nil
    end
  end

  def resolve(user_id) when is_integer(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, integration} when is_binary(integration.default_booking_calendar_id) ->
        integration

      {:ok, integration} ->
        find_integration_with_booking_calendar(user_id) || integration

      {:error, _reason} ->
        integrations = CalendarManagement.list_active_calendar_integrations(user_id)
        Enum.find(integrations, & &1.default_booking_calendar_id) || List.first(integrations)
    end
  end

  def resolve(_other), do: nil

  defp find_integration_with_booking_calendar(user_id) do
    user_id
    |> CalendarManagement.list_active_calendar_integrations()
    |> Enum.find(& &1.default_booking_calendar_id)
  end
end
