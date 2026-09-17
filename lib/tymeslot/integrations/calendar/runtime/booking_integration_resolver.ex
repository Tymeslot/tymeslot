defmodule Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver do
  @moduledoc """
  Resolves which calendar integration owns a booking, given a `Meeting`,
  `MeetingType`, `{integration_id, user_id}` tuple, or bare user id.

  The resolver implements a fallback chain:

  1. If the explicit context names an integration the user owns that can
     still take a booking, that integration is returned (with
     `default_booking_calendar_id` overridden by the context's stored value
     where applicable).
  2. Otherwise the user's primary calendar integration is used.
  3. If the primary has no booking calendar configured, the first
     integration with a booking calendar is used.
  4. Finally, any integration is used.

  Every tier applies the same test, `booking_target?/1`: the integration is
  active, its credentials have not been refused (`needs_reauth`), and its
  provider accepts writes. Read-only integrations (a subscribed feed) can
  block availability but can never receive a booking, so resolving one would
  hand the booking flow an integration that builds no client; see
  `Tymeslot.Integrations.Calendar.BookingEligibility`. A flagged integration
  stays active so the dashboard, the health probe and the token refresh sweep
  keep seeing it, but every write against it fails, retries, and alerts the
  owner, while a working calendar sits unused.
  """

  alias Tymeslot.Integrations.Calendar.BookingEligibility
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
    explicit_target(integration_id, user_id) || resolve(user_id)
  end

  def resolve(%MeetingSchema{calendar_integration_id: integration_id} = meeting)
      when is_integer(integration_id) do
    stored_target(integration_id, meeting.organizer_user_id, meeting.calendar_path) ||
      resolve(meeting.organizer_user_id)
  end

  def resolve(%MeetingSchema{organizer_user_id: user_id}), do: resolve(user_id)

  def resolve(%MeetingTypeSchema{calendar_integration_id: integration_id} = meeting_type)
      when is_integer(integration_id) do
    stored_target(integration_id, meeting_type.user_id, meeting_type.target_calendar_id) ||
      resolve(meeting_type.user_id)
  end

  def resolve(%MeetingTypeSchema{user_id: user_id}), do: resolve(user_id)

  def resolve(user_id) when is_integer(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, integration} when is_binary(integration.default_booking_calendar_id) ->
        if booking_target?(integration),
          do: integration,
          else: fallback_integration(bookable_integrations(user_id))

      {:ok, integration} ->
        integrations = bookable_integrations(user_id)

        find_integration_with_booking_calendar(integrations) ||
          if booking_target?(integration),
            do: integration,
            else: fallback_integration(integrations)

      {:error, _reason} ->
        fallback_integration(bookable_integrations(user_id))
    end
  end

  def resolve(_other), do: nil

  # The integration a meeting or meeting type recorded, writing to the
  # calendar it recorded alongside; nil once that integration can no longer
  # take a booking, so the caller falls through to the user's other calendars.
  defp stored_target(integration_id, user_id, calendar_id) do
    case explicit_target(integration_id, user_id) do
      nil -> nil
      integration -> %{integration | default_booking_calendar_id: calendar_id}
    end
  end

  defp explicit_target(integration_id, user_id) do
    case CalendarManagement.fetch_integration_for_user(integration_id, user_id) do
      {:ok, integration} -> if booking_target?(integration), do: integration
      {:error, :not_found} -> nil
    end
  end

  defp fallback_integration(integrations) do
    Enum.find(integrations, & &1.default_booking_calendar_id) || List.first(integrations)
  end

  defp find_integration_with_booking_calendar(integrations) do
    Enum.find(integrations, & &1.default_booking_calendar_id)
  end

  defp bookable_integrations(user_id) do
    user_id
    |> CalendarManagement.list_active_calendar_integrations()
    |> Enum.filter(&booking_target?/1)
  end

  # The one answer to "can this integration take the booking?", asked by every
  # tier above. Paused and flagged integrations are both excluded here and
  # nowhere else: they stay listed for the dashboard, the health probe and the
  # token refresh sweep, which are what get a flagged one reconnected.
  defp booking_target?(%{is_active: true, needs_reauth: false} = integration),
    do: BookingEligibility.bookable?(integration)

  defp booking_target?(_integration), do: false
end
