defmodule Tymeslot.Integrations.Calendar.Primary do
  @moduledoc """
  Sets a user's primary calendar integration when they choose one, and reads
  it back; `Calendar.PrimaryElection` is what picks one without being asked.

  Making an integration the primary checks that it is active and bookable,
  and gives it a booking calendar. An integration just connected through
  OAuth has its booking calendar chosen here too, from what discovery finds.
  """

  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Profiles.ProfileQueries

  require Logger

  @type user_id :: integer()
  @type integration_id :: integer()

  @doc """
  Sets a calendar integration as the primary for a user.
  """
  @spec set_primary_calendar_integration(user_id(), integration_id()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :not_found | :unauthorized | :not_bookable | :inactive | Ecto.Changeset.t()}
  def set_primary_calendar_integration(user_id, integration_id) do
    with {:ok, integration} <- validate_and_prepare_integration(user_id, integration_id),
         {:ok, _profile} <- update_profile_primary(user_id, integration_id) do
      # We no longer clear other booking calendars here, as booking is managed per meeting type.
      # We just ensure the newly primary integration has a default set for fallback.
      updated = ensure_default_booking_calendar(integration)
      {:ok, updated}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets the primary calendar integration for a user.
  """
  @spec get_primary_calendar_integration(user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found | :no_primary_set}
  def get_primary_calendar_integration(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, %{primary_calendar_integration_id: nil}} ->
        {:error, :no_primary_set}

      {:ok, %{primary_calendar_integration_id: id}} ->
        Management.get_calendar_integration(id, user_id)

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  @doc """
  Discovers the calendars of an integration just connected through OAuth
  (Google, Outlook) and picks its default booking calendar. Falls back to
  returning the integration unchanged if discovery fails.
  """
  @spec discover_and_configure_calendars(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
  def discover_and_configure_calendars(integration) do
    case Discovery.discover_calendars_for_integration(integration) do
      {:ok, calendars} ->
        auto_select_primary_calendar(integration, calendars)

      {:error, reason} ->
        Logger.warning("Calendar discovery failed after OAuth callback",
          provider: integration.provider,
          reason: reason
        )

        {:ok, integration}
    end
  end

  # Private helpers

  # Stores the discovered list and picks the default booking calendar: the
  # one already stored while discovery still finds it, so a reconnect never
  # moves the owner's bookings, else the provider's primary, else a selected
  # one, else the first. Only calendars a booking can be written to are
  # considered (`Defaults.default_booking_calendar/2`), so the id stored here
  # is never one `Defaults.resolve_default_calendar_id/1` would refuse. Only
  # an OAuth connection reaches this, and its discovered entries carry no
  # path, so `calendar_paths` is left alone: it must stay empty for those
  # providers.
  #
  # Both the carried choices and the stored default are read from the row
  # under its lock, not from `integration`, which was read before discovery
  # went to the network: a change the owner made meanwhile is kept.
  defp auto_select_primary_calendar(integration, discovered) do
    discovered = Enum.map(discovered, &CalendarEntry.normalize/1)

    Blocking.replace_selection(integration, fn stored ->
      # A reconnected account keeps whether each calendar it already knew
      # blocks availability; the selection is discovery's, as on any
      # connect, but for its booking calendars, which `Blocking` keeps
      # selected and blocking whatever discovery says.
      calendars = Selection.carry_blocking_choices(discovered, stored.calendar_list)

      case Defaults.default_booking_calendar(calendars, stored.default_booking_calendar_id) do
        %CalendarEntry{id: id} -> {calendars, %{default_booking_calendar_id: id}}
        nil -> {calendars, %{}}
      end
    end)
  end

  defp validate_and_prepare_integration(user_id, integration_id) do
    with {:ok, integration} <-
           Management.get_calendar_integration(integration_id, user_id),
         :ok <- verify_active(integration),
         :ok <- verify_bookable(integration) do
      {:ok, integration}
    else
      {:error, error_reason} -> {:error, error_reason}
    end
  end

  # A read-only provider can never be the calendar bookings are written to.
  # This is the single choke point every caller of
  # `set_primary_calendar_integration/2` goes through, so the invariant holds
  # regardless of whether the caller reached here from creation, a toggle, or
  # a deletion promotion.
  defp verify_bookable(%CalendarIntegrationSchema{} = integration) do
    if BookingEligibility.bookable?(integration) do
      :ok
    else
      {:error, :not_bookable}
    end
  end

  # A paused integration is never the calendar bookings are written to: the
  # booking path would refuse it and fall back elsewhere, while the dashboard
  # went on showing it as the primary.
  defp verify_active(%CalendarIntegrationSchema{is_active: true}), do: :ok
  defp verify_active(%CalendarIntegrationSchema{}), do: {:error, :inactive}

  defp update_profile_primary(user_id, integration_id) do
    ProfileQueries.set_primary_calendar_integration(user_id, integration_id)
  end

  defp ensure_default_booking_calendar(%CalendarIntegrationSchema{} = integration) do
    if is_nil(integration.default_booking_calendar_id) do
      with calendar_id when is_binary(calendar_id) <-
             Defaults.resolve_default_calendar_id(integration),
           {:ok, updated} <- Blocking.set_default_booking_calendar(integration, calendar_id) do
        updated
      else
        _error -> integration
      end
    else
      integration
    end
  end
end
