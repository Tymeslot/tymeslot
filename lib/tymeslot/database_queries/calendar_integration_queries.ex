defmodule Tymeslot.DatabaseQueries.CalendarIntegrationQueries do
  @moduledoc """
  Database queries for calendar integrations.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.Repo

  @doc """
  Gets all active calendar integrations for a user.
  """
  @spec list_active_for_user(integer()) :: [CalendarIntegrationSchema.t()]
  def list_active_for_user(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id and c.is_active == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets all active calendar integrations across all users.
  Used for health checks and monitoring.
  """
  @spec list_all_active() :: list(CalendarIntegrationSchema.t())
  def list_all_active do
    CalendarIntegrationSchema
    |> where([c], c.is_active == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets all calendar integrations for a user (including inactive).
  """
  @spec list_all_for_user(integer()) :: [CalendarIntegrationSchema.t()]
  def list_all_for_user(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], asc: c.name)
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets a single calendar integration by ID.
  WARNING: This function does not check user authorization.
  Use get_for_user/2 instead for secure access.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get(integer()) :: {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(CalendarIntegrationSchema, id) do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Gets a calendar integration by ID for a specific user.
  This is the secure version that checks user authorization.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get_for_user(integer(), integer()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_for_user(id, user_id) do
    result =
      CalendarIntegrationSchema
      |> where([c], c.id == ^id and c.user_id == ^user_id)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Gets a calendar integration by user ID and provider.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get_by_user_and_provider(integer(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_by_user_and_provider(user_id, provider) do
    result =
      CalendarIntegrationSchema
      |> where([c], c.user_id == ^user_id and c.provider == ^provider)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Creates a new calendar integration.
  """
  @spec create(map()) :: {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %CalendarIntegrationSchema{}
    |> CalendarIntegrationSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a new calendar integration with automatic primary setting if it's the first.
  Uses a transaction to ensure atomicity.
  """
  @spec create_with_auto_primary(map()) :: {:ok, CalendarIntegrationSchema.t()} | {:error, term()}
  def create_with_auto_primary(attrs) do
    Repo.transaction(fn ->
      case create(attrs) do
        {:ok, integration} ->
          maybe_set_as_primary(integration)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp maybe_set_as_primary(integration) do
    user_id = integration.user_id

    # Count existing integrations before this one
    existing_count = count_for_user(user_id)

    # If the profile has no primary OR this is the first integration, set as primary
    alias Tymeslot.DatabaseQueries.ProfileQueries

    need_primary =
      case ProfileQueries.get_by_user_id(user_id) do
        {:ok, %{primary_calendar_integration_id: nil}} -> true
        {:ok, _profile} -> existing_count == 1
        {:error, _} -> existing_count == 1
      end

    if need_primary do
      set_integration_as_primary(integration)
    else
      integration
    end
  end

  defp set_integration_as_primary(integration) do
    # Import ProfileQueries to set primary
    alias Tymeslot.DatabaseQueries.ProfileQueries

    # Clear other booking calendars and set this as primary
    clear_others_fn = fn ->
      # No need to clear others for the first integration
      :ok
    end

    case ProfileQueries.set_primary_calendar_integration_transactional(
           integration.user_id,
           integration.id,
           clear_others_fn
         ) do
      {:ok, _profile} -> integration
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Updates a calendar integration.
  """
  @spec update(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%CalendarIntegrationSchema{} = integration, attrs) do
    integration
    |> CalendarIntegrationSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a calendar integration.
  """
  @spec delete(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%CalendarIntegrationSchema{} = integration) do
    Repo.delete(integration)
  end

  @doc """
  Updates the last sync timestamp and clears any error.
  """
  @spec mark_sync_success(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_sync_success(%CalendarIntegrationSchema{} = integration) do
    integration
    |> Changeset.change(%{
      last_sync_at: DateTime.truncate(DateTime.utc_now(), :second),
      sync_error: nil
    })
    |> Repo.update()
  end

  @doc """
  Updates the sync error message.
  """
  @spec mark_sync_error(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_sync_error(%CalendarIntegrationSchema{} = integration, error_message) do
    integration
    |> Changeset.change(%{
      sync_error: error_message
    })
    |> Repo.update()
  end

  @doc """
  Toggles the active status of an integration.
  """
  @spec toggle_active(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_active(%CalendarIntegrationSchema{} = integration) do
    integration
    |> Changeset.change(%{is_active: !integration.is_active})
    |> Repo.update()
  end

  @doc """
  Lists Google Calendar integrations with tokens expiring before the given threshold.
  """
  @spec list_expiring_google_tokens(DateTime.t()) :: [CalendarIntegrationSchema.t()]
  def list_expiring_google_tokens(threshold_datetime) do
    CalendarIntegrationSchema
    |> where([c], c.provider == "google")
    |> where([c], c.is_active == true)
    |> where([c], c.token_expires_at < ^threshold_datetime)
    |> where([c], not is_nil(c.refresh_token_encrypted))
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_oauth_tokens/1)
  end

  @doc """
  Lists Outlook Calendar integrations with tokens expiring before the given threshold.
  """
  @spec list_expiring_outlook_tokens(DateTime.t()) :: [CalendarIntegrationSchema.t()]
  def list_expiring_outlook_tokens(threshold_datetime) do
    CalendarIntegrationSchema
    |> where([c], c.provider == "outlook")
    |> where([c], c.is_active == true)
    |> where([c], c.token_expires_at < ^threshold_datetime)
    |> where([c], not is_nil(c.refresh_token_encrypted))
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_oauth_tokens/1)
  end

  @doc """
  Updates a calendar integration - alias for update/2.
  """
  @spec update_integration(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_integration(%CalendarIntegrationSchema{} = integration, attrs) do
    integration
    |> CalendarIntegrationSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Counts calendar integrations for a user.
  """
  @spec count_for_user(integer()) :: non_neg_integer()
  def count_for_user(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id)
    |> select([c], count(c.id))
    |> Repo.one() || 0
  end

  @doc """
  Gets all calendar integrations (for consistency checks).
  Used by data consistency service.
  """
  @spec list_all() :: list(CalendarIntegrationSchema.t())
  def list_all do
    CalendarIntegrationSchema
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Executes a function or Ecto.Multi within a database transaction.
  """
  @spec transaction((-> any()) | Ecto.Multi.t()) ::
          {:ok, any()} | {:error, any()} | {:ok, map()} | {:error, any(), any(), map()}
  def transaction(fun_or_multi) do
    Repo.transaction(fun_or_multi)
  end

  @doc """
  Rolls back the current transaction with the given reason.
  """
  @spec rollback(any()) :: no_return()
  def rollback(reason) do
    Repo.rollback(reason)
  end

  @doc """
  Checks whether the user already has a default booking calendar set.
  """
  @spec user_has_default_booking_calendar?(integer()) :: boolean()
  def user_has_default_booking_calendar?(user_id) do
    Repo.exists?(
      from(ci in CalendarIntegrationSchema,
        where: ci.user_id == ^user_id and not is_nil(ci.default_booking_calendar_id)
      )
    )
  end

  @doc """
  Locks the user's profile row and all calendar integration rows for that user.
  Used to coordinate primary rebalance operations without race conditions.
  """
  @spec lock_user_profile_and_integrations(integer()) :: :ok
  def lock_user_profile_and_integrations(user_id) do
    _ =
      Repo.one(
        from(p in ProfileSchema,
          where: p.user_id == ^user_id,
          lock: "FOR UPDATE"
        )
      )

    _ =
      Repo.all(
        from(ci in CalendarIntegrationSchema,
          where: ci.user_id == ^user_id,
          select: ci.id,
          lock: "FOR UPDATE"
        )
      )

    :ok
  end
end
