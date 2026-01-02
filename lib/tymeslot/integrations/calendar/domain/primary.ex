defmodule Tymeslot.Integrations.CalendarPrimary do
  @moduledoc """
  Context for managing primary and booking calendar selection.

  Handles setting primary calendars, managing booking calendars,
  and automatic primary calendar selection logic.
  """

  alias Tymeslot.DatabaseQueries.{CalendarIntegrationQueries, ProfileQueries}
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.CalendarManagement

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
      # After clearing other booking calendars and setting profile primary,
      # ensure the chosen integration has a default booking calendar set (if needed).
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

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Clears all booking calendars for a user except the specified one.
  Used when setting a new primary calendar.
  """
  @spec clear_booking_calendars_for_user(user_id(), integration_id() | nil) :: :ok
  def clear_booking_calendars_for_user(user_id, except_integration_id \\ nil) do
    integrations = CalendarManagement.list_calendar_integrations(user_id)

    Enum.each(integrations, fn integration ->
      if integration.id != except_integration_id &&
           !is_nil(integration.default_booking_calendar_id) do
        CalendarManagement.update_calendar_integration(integration, %{
          default_booking_calendar_id: nil
        })
      end
    end)

    :ok
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
        _ -> false
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

  # Private helpers

  defp validate_and_prepare_integration(user_id, integration_id) do
    with {:ok, integration} <-
           CalendarManagement.get_calendar_integration(integration_id, user_id),
         :ok <- verify_integration_ownership(integration, user_id) do
      {:ok, integration}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_profile_primary(user_id, integration_id) do
    clear_others_fn = fn ->
      clear_booking_calendars_for_user(user_id, integration_id)
    end

    ProfileQueries.set_primary_calendar_integration_transactional(
      user_id,
      integration_id,
      clear_others_fn
    )
  end

  defp verify_integration_ownership(%CalendarIntegrationSchema{user_id: user_id}, user_id),
    do: :ok

  defp verify_integration_ownership(_, _), do: {:error, :unauthorized}

  defp ensure_default_booking_calendar(%CalendarIntegrationSchema{} = integration) do
    if is_nil(integration.default_booking_calendar_id) do
      with calendar_id when not is_nil(calendar_id) <-
             Defaults.resolve_default_calendar_id(integration),
           {:ok, updated} <-
             CalendarManagement.update_calendar_integration(integration, %{
               default_booking_calendar_id: calendar_id
             }) do
        updated
      else
        _ -> integration
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
