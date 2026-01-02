defmodule Tymeslot.Integrations.CalendarManagement do
  @moduledoc """
  Context for calendar integration CRUD operations.

  Handles creation, reading, updating, and deletion of calendar integrations,
  separated from primary calendar logic and discovery operations.
  """

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.CalendarPrimary
  require Logger

  @type user_id :: integer()
  @type integration_id :: integer()
  @type integration_attrs :: map()

  @doc """
  Lists all calendar integrations for a user.
  """
  @spec list_calendar_integrations(user_id()) :: [CalendarIntegrationSchema.t()]
  def list_calendar_integrations(user_id) do
    CalendarIntegrationQueries.list_all_for_user(user_id)
  end

  @doc """
  Lists only active calendar integrations for a user.
  """
  @spec list_active_calendar_integrations(user_id()) :: [CalendarIntegrationSchema.t()]
  def list_active_calendar_integrations(user_id) do
    CalendarIntegrationQueries.list_active_for_user(user_id)
  end

  @doc """
  Gets a single calendar integration.
  """
  @spec get_calendar_integration(integration_id(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found | :unauthorized}
  def get_calendar_integration(integration_id, user_id) do
    CalendarIntegrationQueries.get_for_user(integration_id, user_id)
  end

  @doc """
  Creates a new calendar integration.
  Automatically sets as primary if it's the user's first calendar.
  """
  @spec create_calendar_integration(integration_attrs()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_calendar_integration(attrs) do
    with {:ok, discovered_attrs} <-
           Discovery.maybe_discover_calendars(normalize_provider_attrs(attrs)),
         {:ok, integration} <-
           CalendarIntegrationQueries.create_with_auto_primary(discovered_attrs),
         {:ok, final_integration} <- ensure_default_booking_calendar(integration) do
      {:ok, final_integration}
    else
      other -> other
    end
  end

  @doc """
  Toggle an integration and rebalance the user's primary calendar atomically.
  Ensures that primary rules are preserved even under concurrent updates.
  """
  @spec toggle_with_primary_rebalance(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def toggle_with_primary_rebalance(%CalendarIntegrationSchema{} = integration) do
    CalendarIntegrationQueries.transaction(fn ->
      CalendarIntegrationQueries.lock_user_profile_and_integrations(integration.user_id)

      current_primary_id = get_current_primary_id(integration.user_id)

      case CalendarIntegrationQueries.toggle_active(integration) do
        {:ok, updated} ->
          maybe_rebalance_primary(updated, current_primary_id)
          updated

        error ->
          CalendarIntegrationQueries.rollback(error)
      end
    end)
  end

  @doc """
  Updates a calendar integration.
  """
  @spec update_calendar_integration(CalendarIntegrationSchema.t(), integration_attrs()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_calendar_integration(integration, attrs) do
    CalendarIntegrationQueries.update(integration, attrs)
  end

  @doc """
  Deletes a calendar integration.
  Handles primary calendar reassignment if needed.
  """
  @spec delete_calendar_integration(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_calendar_integration(integration) do
    CalendarPrimary.delete_with_primary_handling(integration)
  end

  @doc """
  Toggles the active status of an integration.
  """
  @spec toggle_calendar_integration(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_calendar_integration(integration) do
    CalendarIntegrationQueries.toggle_active(integration)
  end

  @doc """
  Updates the last sync timestamp for an integration.
  """
  @spec mark_sync_success(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_sync_success(integration) do
    CalendarIntegrationQueries.mark_sync_success(integration)
  end

  @doc """
  Records a sync error for an integration.
  """
  @spec mark_sync_error(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_sync_error(integration, error_message) do
    CalendarIntegrationQueries.mark_sync_error(integration, error_message)
  end

  @doc """
  Normalizes provider-specific attributes before creation or update.
  Public function that adds value by handling provider-specific quirks.
  """
  @spec normalize_provider_attrs(map()) :: map()
  def normalize_provider_attrs(attrs) do
    provider = attrs[:provider] || attrs["provider"]

    case provider do
      :nextcloud -> normalize_nextcloud_attrs(attrs)
      "nextcloud" -> normalize_nextcloud_attrs(attrs)
      _ -> attrs
    end
  end

  # Private helpers

  defp ensure_default_booking_calendar(%{default_booking_calendar_id: nil} = integration) do
    # Only set a default booking calendar automatically if the user doesn't
    # already have one (to satisfy the unique_booking_calendar_per_user constraint
    # and keep the existing primary unchanged when adding more integrations).
    if has_existing_default?(integration.user_id) do
      {:ok, integration}
    else
      set_default_booking_calendar(integration)
    end
  end

  defp ensure_default_booking_calendar(integration), do: {:ok, integration}

  defp has_existing_default?(user_id) do
    CalendarIntegrationQueries.user_has_default_booking_calendar?(user_id)
  end

  defp set_default_booking_calendar(integration) do
    case Defaults.resolve_default_calendar_id(integration) do
      nil ->
        {:ok, integration}

      default_id ->
        update_default_booking_calendar(integration, default_id)
    end
  end

  defp update_default_booking_calendar(integration, default_id) do
    case CalendarIntegrationQueries.update(integration, %{
           default_booking_calendar_id: default_id
         }) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_booking_calendar_update_error(integration, changeset)
    end
  end

  defp handle_booking_calendar_update_error(integration, changeset) do
    if unique_booking_calendar_conflict?(changeset) do
      # If the unique constraint is hit (another integration already has a default),
      # keep the existing primary/default and proceed without error.
      {:ok, integration}
    else
      Logger.error("Failed to set default booking calendar",
        user_id: integration.user_id,
        integration_id: integration.id,
        errors: changeset.errors
      )

      {:error, changeset}
    end
  end

  defp unique_booking_calendar_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:default_booking_calendar_id, {_msg, opts}} ->
        opts[:constraint] == :unique &&
          to_string(opts[:constraint_name]) == "unique_booking_calendar_per_user"

      _ ->
        false
    end)
  end

  defp get_current_primary_id(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, primary} -> primary.id
      _ -> nil
    end
  end

  defp maybe_rebalance_primary(%{is_active: false, id: id, user_id: uid}, current_primary_id)
       when current_primary_id == id do
    promote_or_clear_primary(uid)
    :ok
  end

  defp maybe_rebalance_primary(
         %{is_active: true, id: updated_id, user_id: uid},
         _current_primary_id
       ) do
    ensure_primary_on_activate(uid, updated_id)
    :ok
  end

  defp maybe_rebalance_primary(_updated, _current_primary_id), do: :ok

  defp promote_or_clear_primary(user_id) do
    case list_active_calendar_integrations(user_id) do
      [] ->
        ProfileQueries.clear_primary_calendar_integration(user_id)

      actives ->
        next = actives |> Enum.sort_by(& &1.inserted_at) |> List.last()
        if next, do: CalendarPrimary.set_primary_calendar_integration(user_id, next.id)
    end
  end

  defp ensure_primary_on_activate(user_id, updated_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, primary} ->
        if primary.is_active == false do
          CalendarPrimary.set_primary_calendar_integration(user_id, updated_id)
        end

      {:error, _} ->
        CalendarPrimary.set_primary_calendar_integration(user_id, updated_id)
    end
  end

  defp normalize_nextcloud_attrs(%{base_url: url} = attrs) when is_binary(url) do
    # Remove any trailing slashes and paths from Nextcloud URL (atom keys)
    normalized_url =
      url
      |> String.trim()
      |> String.trim_trailing("/")
      |> remove_nextcloud_paths()

    Map.put(attrs, :base_url, normalized_url)
  end

  defp normalize_nextcloud_attrs(%{"base_url" => url} = attrs) when is_binary(url) do
    # Remove any trailing slashes and paths from Nextcloud URL (string keys)
    normalized_url =
      url
      |> String.trim()
      |> String.trim_trailing("/")
      |> remove_nextcloud_paths()

    Map.put(attrs, "base_url", normalized_url)
  end

  defp remove_nextcloud_paths(url) do
    # Remove common Nextcloud paths
    url
    |> String.replace(~r"/remote\.php/dav.*$", "")
    |> String.replace(~r"/remote\.php/webdav.*$", "")
    |> String.replace(~r"/nextcloud.*$", "")
    |> String.replace(~r"/cloud.*$", "")
    |> String.replace(~r"/owncloud.*$", "")
  end
end
