defmodule Tymeslot.Integrations.CalendarManagement do
  @moduledoc """
  Context for calendar integration CRUD operations.

  Handles creation, reading, updating, and deletion of calendar integrations,
  separated from primary calendar logic and discovery operations.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.PrimarySelection
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
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
  The user's calendar display preferences. Returns the stored row if one
  exists, otherwise an unsaved struct populated with defaults — callers that
  need the defaults persisted must call `save_preferences/2` themselves.
  """
  @spec get_or_create_preferences(user_id()) :: struct()
  def get_or_create_preferences(user_id) do
    CalendarPreferencesQueries.get_or_create(user_id)
  end

  @doc """
  Upserts the user's calendar display preferences.
  """
  @spec save_preferences(user_id(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def save_preferences(user_id, attrs) do
    CalendarPreferencesQueries.upsert(user_id, attrs)
  end

  @doc """
  Gets a single calendar integration, returning a two-outcome tuple.

  Delegates to `fetch_integration_for_user/2` so that a
  `{:error, :requires_reencryption, _}` result is silently flagged and
  collapsed to `{:error, :not_found}` before it reaches callers.
  """
  @spec get_calendar_integration(integration_id(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_calendar_integration(integration_id, user_id) do
    fetch_integration_for_user(integration_id, user_id)
  end

  @doc """
  Fetches a calendar integration by ID for a user, collapsing the
  `{:error, :requires_reencryption, integration}` arm into `{:error, :not_found}`
  after silently flagging the integration for reauthentication.

  Use this in non-Oban callers that only care about the two-outcome
  `{:ok, _} | {:error, :not_found}` shape.
  """
  @spec fetch_integration_for_user(integration_id(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def fetch_integration_for_user(integration_id, user_id) do
    case CalendarIntegrationQueries.get_for_user(integration_id, user_id) do
      {:ok, integration} ->
        {:ok, integration}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :requires_reencryption, stale} ->
        flag_for_reauth(stale)
        {:error, :not_found}
    end
  end

  @doc """
  Creates a new calendar integration.
  Automatically sets as primary if it's the user's first calendar.
  """
  @spec create_calendar_integration(integration_attrs()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_calendar_integration(attrs) do
    with {:ok, discovered_attrs} <- Discovery.maybe_discover_calendars(attrs),
         {:ok, integration} <-
           PrimarySelection.create_with_auto_primary(discovered_attrs),
         {:ok, final_integration} <- ensure_default_booking_calendar(integration) do
      :telemetry.execute([:tymeslot, :calendar, :connected], %{count: 1}, %{
        provider: final_integration.provider
      })

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
    Repo.transaction(fn ->
      CalendarIntegrationWebhookQueries.lock_user_profile_and_integrations(integration.user_id)

      current_primary_id = get_current_primary_id(integration.user_id)

      case CalendarIntegrationQueries.toggle_active(integration) do
        {:ok, updated} ->
          maybe_rebalance_primary(updated, current_primary_id)
          updated

        error ->
          Repo.rollback(error)
      end
    end)
  end

  @doc """
  Updates a calendar integration.

  When the attrs carry credentials — i.e. the owner has supplied fresh ones via
  a reconnect form — `needs_reauth` is cleared, the integration's health state
  row is reset, and an immediate verification probe is enqueued so the in-app
  badge clears without waiting up to an hour for the next scheduled probe.
  """
  @spec update_calendar_integration(CalendarIntegrationSchema.t(), integration_attrs()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_calendar_integration(integration, attrs) do
    if credentials_in_attrs?(attrs) do
      update_with_credentials(integration, attrs)
    else
      CalendarIntegrationQueries.update(integration, attrs)
    end
  end

  defp update_with_credentials(integration, attrs) do
    with {:ok, updated} = ok <- CalendarIntegrationQueries.update_credentials(integration, attrs) do
      HealthCheck.mark_user_recovered(:calendar, updated.id)
      ok
    end
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

  Reactivating clears the health state row and enqueues an immediate probe so
  the badge can't lie about an integration the user has just turned back on.
  """
  @spec toggle_calendar_integration(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_calendar_integration(integration) do
    case CalendarIntegrationQueries.toggle_active(integration) do
      {:ok, %{is_active: true} = updated} = ok ->
        HealthCheck.mark_user_recovered(:calendar, updated.id)
        ok

      result ->
        result
    end
  end

  @doc """
  Updates the last sync timestamp for an integration.

  A successful sync is the strongest possible signal that the integration
  works, so the health state row is reset on every success. Without this, a
  flaky probe can leave the badge stuck on `:unhealthy` even while real syncs
  succeed every few minutes.
  """
  @spec mark_sync_success(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_sync_success(integration) do
    case CalendarIntegrationQueries.mark_sync_success(integration) do
      {:ok, updated} = ok ->
        HealthCheck.mark_synced_successfully(:calendar, updated.id)
        ok

      error ->
        error
    end
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
  Flags an integration as needing reauthentication when its stored credentials
  can no longer be decrypted. Also records the sync error so the dashboard
  shows the same message the worker logged.
  """
  @spec mark_needs_reauth(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_needs_reauth(integration, error_message) do
    CalendarIntegrationQueries.mark_needs_reauth(integration, error_message)
  end

  @doc """
  Entry point for the "credentials no longer decrypt" path, used by any
  worker or caller that receives `{:error, :requires_reencryption, integration}`
  from `CalendarIntegrationQueries.get/1`.

  Pass `cause: cause` (see `t:Tymeslot.Integrations.Shared.ReauthHandling.cause/0`)
  when the integration needs reconnecting for a different reason, so the message
  recorded on `sync_error` describes what actually failed.

  Returns an Oban return value: `{:discard, _}` on success (retrying won't
  recover the credentials), or `{:error, _}` if the flag couldn't be persisted —
  which causes Oban to retry the job and take another shot at recording the flag.
  """
  @spec handle_reauth_required(CalendarIntegrationSchema.t(), keyword()) ::
          {:discard, String.t()} | {:error, String.t()}
  def handle_reauth_required(%CalendarIntegrationSchema{} = integration, opts \\ []) do
    case flag_for_reauth(integration, opts) do
      :ok -> {:discard, "Credentials require reauthentication"}
      {:error, _changeset} -> {:error, "Failed to flag integration for reauth"}
    end
  end

  @doc """
  Flags an integration for reconnection and returns the Oban value a worker
  should return, for failures only the owner can resolve: a deleted booking
  calendar, or credentials the provider now rejects.

  `message` is the translated explanation shown on the dashboard;
  `discard_reason` is the operator-facing reason recorded on the job.

  Discarding rather than returning `{:error, _}` is the point. Retrying re-asks
  a question already answered, and an exhausted retry chain raises a
  permanent-failure admin alert about a condition no operator can fix.
  A failed *flag write* is worth retrying, though: without it the dashboard
  never tells the owner why their calendar stopped syncing.
  """
  @spec flag_for_reconnection(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          {:discard, String.t()} | {:error, String.t()}
  def flag_for_reconnection(%CalendarIntegrationSchema{} = integration, message, discard_reason) do
    case mark_needs_reauth(integration, message) do
      {:ok, _updated} -> {:discard, discard_reason}
      {:error, _changeset} -> {:error, "Failed to flag integration: #{discard_reason}"}
    end
  end

  @doc """
  Fetches a calendar integration by ID, collapsing the
  `{:error, :requires_reencryption, integration}` arm into `{:error, :not_found}`
  after silently flagging the integration for reauthentication.

  Use this in non-Oban callers that only care about the two-outcome
  `{:ok, _} | {:error, :not_found}` shape.
  """
  @spec fetch_integration(integer()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def fetch_integration(id) do
    case CalendarIntegrationQueries.get(id) do
      {:ok, integration} ->
        {:ok, integration}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :requires_reencryption, stale} ->
        flag_for_reauth(stale)
        {:error, :not_found}
    end
  end

  # Shared helper: delegates to ReauthHandling.flag/2 with calendar-specific opts.
  defp flag_for_reauth(integration, opts \\ []) do
    ReauthHandling.flag(
      integration,
      Keyword.merge(
        [mark_needs_reauth: &mark_needs_reauth/2, log_prefix: "Calendar"],
        opts
      )
    )
  end

  # Callers supply the virtual field names (`:password`), never the encrypted
  # ones — those only exist after `encrypt_credentials/1` runs inside the
  # changeset, by which point the attrs have already been consumed.
  defp credentials_in_attrs?(attrs) when is_map(attrs) do
    fields = CalendarIntegrationSchema.credential_fields()

    Enum.any?(fields, fn f -> Map.has_key?(attrs, f) or Map.has_key?(attrs, Atom.to_string(f)) end)
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

      _other ->
        false
    end)
  end

  defp get_current_primary_id(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, primary} -> primary.id
      _other -> nil
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
    eligible =
      user_id
      |> list_active_calendar_integrations()
      |> Enum.reject(&ProviderConfig.subscription?(&1.provider))

    case eligible do
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

      {:error, _reason} ->
        CalendarPrimary.set_primary_calendar_integration(user_id, updated_id)
    end
  end
end
