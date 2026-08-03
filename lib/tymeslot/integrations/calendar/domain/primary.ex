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
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Selection
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
          | {:error, :not_found | :unauthorized | :not_bookable | Ecto.Changeset.t()}
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
    oauth? =
      case ProviderConfig.parse_known(integration.provider) do
        {:ok, provider_atom} -> ProviderConfig.oauth_provider?(provider_atom)
        {:error, :unknown} -> false
      end

    # Restrict the ladder to calendars eligible for booking (not read-only)
    # so the id persisted here is never one `Defaults.resolve_default_calendar_id/1`
    # — the read path — would then refuse to honour.
    eligible = Defaults.eligible_for_booking(calendars)

    # Find the default booking calendar
    default_calendar_id =
      if oauth? do
        # For OAuth, prefer provider primary, then selected, then first
        Defaults.primary_id(eligible) || Defaults.selected_id(eligible) ||
          Defaults.first_id_from_list(eligible)
      else
        # For CalDAV/Radicale, prefer selected, else first
        Defaults.selected_id(eligible) || Defaults.first_id_from_list(eligible)
      end

    # Update with calendar list and default booking calendar if found.
    # For CalDAV-family providers, `calendar_list_attrs/1` keeps `calendar_paths`
    # in sync with the selection — required so the CalDAV worker only fetches
    # calendars the user has activated.
    # For OAuth providers (Google, Outlook), the discovery maps are atom-keyed
    # and carry no `:path` key, so passing them through `calendar_list_attrs/1`
    # would write provider IDs (e.g. "primary") into `calendar_paths` — a field
    # that must stay empty for OAuth integrations. Only write `calendar_list`
    # for those providers.
    attrs =
      if oauth? do
        %{calendar_list: calendars}
      else
        Selection.calendar_list_attrs(calendars)
      end

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
         :ok <- verify_integration_ownership(integration, user_id),
         :ok <- verify_bookable(integration) do
      {:ok, integration}
    else
      {:error, error_reason} -> {:error, error_reason}
    end
  end

  # A subscription is read-only, so it can never be the calendar bookings are
  # written to. This is the single choke point every caller of
  # `set_primary_calendar_integration/2` goes through, so the invariant holds
  # regardless of whether the caller reached here from creation, a toggle, or
  # a deletion promotion.
  defp verify_bookable(%CalendarIntegrationSchema{provider: provider}) do
    if ProviderConfig.subscription?(provider) do
      {:error, :not_bookable}
    else
      :ok
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
    eligible_integrations =
      user_id
      |> CalendarManagement.list_calendar_integrations()
      |> Enum.reject(&ProviderConfig.subscription?(&1.provider))

    case eligible_integrations do
      [] ->
        # No bookable calendars left, clear the primary in the profile
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
