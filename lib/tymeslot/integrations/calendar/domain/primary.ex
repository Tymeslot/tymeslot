defmodule Tymeslot.Integrations.CalendarPrimary do
  @moduledoc """
  Context for managing primary and booking calendar selection.

  Handles setting primary calendars, managing booking calendars,
  and automatic primary calendar selection logic.
  """

  alias Tymeslot.Integrations.Calendar, as: CalendarContext
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Profiles.ProfileQueries

  require Logger

  @type user_id :: integer()
  @type integration_id :: integer()

  @doc """
  Sets a calendar integration as the primary for a user.
  """
  @spec set_primary_calendar_integration(user_id(), integration_id()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
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
        CalendarManagement.get_calendar_integration(id, user_id)

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a calendar integration with primary calendar handling.
  If deleting the primary calendar, automatically promotes another one.
  """
  @spec delete_with_primary_handling(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_with_primary_handling(integration) do
    user_id = integration.user_id
    integration_id = integration.id

    # Check if this is the primary integration
    is_primary =
      case ProfileQueries.get_by_user_id(user_id) do
        {:ok, profile} -> profile.primary_calendar_integration_id == integration_id
        _error -> false
      end

    # Delete the integration
    case CalendarIntegrationQueries.delete(integration) do
      {:ok, _deleted} = success ->
        # If we deleted the primary calendar, auto-promote the next one
        if is_primary do
          handle_primary_deletion(user_id)
        end

        success

      error ->
        error
    end
  end

  @doc """
  Auto-selects the primary calendar after discovery for all providers.
  For OAuth providers, looks for a calendar marked as primary.
  For CalDAV/Radicale, selects the first available calendar.
  """
  @spec auto_select_primary_calendar(CalendarIntegrationSchema.t(), [map()]) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def auto_select_primary_calendar(integration, calendars) do
    alias Tymeslot.Integrations.Calendar.ProviderConfig

    # Find the default booking calendar
    default_calendar_id =
      if ProviderConfig.oauth_provider?(
           try do
             String.to_existing_atom(integration.provider)
           rescue
             ArgumentError -> :unknown
           end
         ) do
        # For OAuth, prefer provider primary, then selected, then first
        Defaults.primary_id(calendars) || Defaults.selected_id(calendars) ||
          Defaults.first_id_from_list(calendars)
      else
        # For CalDAV/Radicale, prefer selected, else first
        Defaults.selected_id(calendars) || Defaults.first_id_from_list(calendars)
      end

    # Update with calendar list and default booking calendar if found
    attrs = %{calendar_list: calendars}

    attrs =
      if default_calendar_id do
        Map.put(attrs, :default_booking_calendar_id, default_calendar_id)
      else
        attrs
      end

    CalendarManagement.update_calendar_integration(integration, attrs)
  end

  @doc """
  Discovers calendars for an integration and auto-selects the primary.
  Falls back to returning the integration unchanged if discovery fails.
  """
  @spec discover_and_configure_calendars(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
  def discover_and_configure_calendars(integration) do
    case CalendarContext.discover_calendars_for_integration(integration) do
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

  defp validate_and_prepare_integration(user_id, integration_id) do
    with {:ok, integration} <-
           CalendarManagement.get_calendar_integration(integration_id, user_id),
         :ok <- verify_integration_ownership(integration, user_id) do
      {:ok, integration}
    else
      {:error, error_reason} -> {:error, error_reason}
    end
  end

  defp update_profile_primary(user_id, integration_id) do
    ProfileQueries.set_primary_calendar_integration(user_id, integration_id)
  end

  defp verify_integration_ownership(%CalendarIntegrationSchema{user_id: user_id}, user_id),
    do: :ok

  defp verify_integration_ownership(_integration, _different_user_id), do: {:error, :unauthorized}

  defp ensure_default_booking_calendar(%CalendarIntegrationSchema{} = integration) do
    if is_nil(integration.default_booking_calendar_id) do
      with calendar_id when is_binary(calendar_id) <-
             Defaults.resolve_default_calendar_id(integration),
           {:ok, updated} <-
             CalendarManagement.update_calendar_integration(integration, %{
               default_booking_calendar_id: calendar_id
             }) do
        updated
      else
        _error -> integration
      end
    else
      integration
    end
  end

  defp handle_primary_deletion(user_id) do
    remaining_integrations = CalendarManagement.list_calendar_integrations(user_id)

    case remaining_integrations do
      [] ->
        # No more calendars, clear the primary in the profile
        ProfileQueries.clear_primary_calendar_integration(user_id)
        :ok

      integrations ->
        # Promote the last available integration deterministically by insertion time
        next_integration =
          integrations
          |> Enum.sort_by(& &1.inserted_at)
          |> List.last()

        set_primary_calendar_integration(user_id, next_integration.id)
        :ok
    end
  end
end
