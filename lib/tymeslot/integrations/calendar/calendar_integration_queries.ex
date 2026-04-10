defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationQueries do
  @moduledoc """
  Database queries for calendar integrations.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
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
  Streams all active calendar integrations in batches, reducing over them with
  the given accumulator. Uses `Repo.stream/2` inside a transaction to avoid
  loading all rows into memory at once.

  `fun` receives each decrypted integration and the current accumulator.
  Returns the final accumulator value.
  """
  @spec stream_all_active(pos_integer(), acc, (CalendarIntegrationSchema.t(), acc -> acc)) :: acc
        when acc: term()
  def stream_all_active(max_rows \\ 100, initial_acc, fun) when is_function(fun, 2) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          CalendarIntegrationSchema
          |> where([c], c.is_active == true)
          |> order_by([c], asc: c.id)
          |> Repo.stream(max_rows: max_rows)
          |> Enum.reduce(initial_acc, fn row, acc ->
            fun.(CalendarIntegrationSchema.decrypt_credentials(row), acc)
          end)
        end,
        timeout: :infinity
      )

    result
  end

  @doc """
  Gets all calendar integrations for a user (including inactive).
  """
  @spec list_all_for_user(integer()) :: [CalendarIntegrationSchema.t()]
  def list_all_for_user(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], desc: c.is_active, asc: c.name)
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
  Finds an active calendar integration by provider and account ID for a user.
  """
  @spec get_by_account_for_user(integer(), String.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_by_account_for_user(user_id, provider, provider_account_id)
      when is_integer(user_id) and is_binary(provider) and is_binary(provider_account_id) do
    result =
      CalendarIntegrationSchema
      |> where(
        [c],
        c.user_id == ^user_id and
          c.provider == ^provider and
          c.provider_account_id == ^provider_account_id and
          c.is_active == true
      )
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Finds any calendar integration (active or inactive) by provider and account ID for a user.
  Used to detect inactive duplicates before creating a new row.
  """
  @spec get_any_by_account_for_user(integer(), String.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_any_by_account_for_user(user_id, provider, provider_account_id)
      when is_integer(user_id) and is_binary(provider) and is_binary(provider_account_id) do
    result =
      CalendarIntegrationSchema
      |> where(
        [c],
        c.user_id == ^user_id and
          c.provider == ^provider and
          c.provider_account_id == ^provider_account_id
      )
      |> order_by([c], desc: c.is_active)
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
      last_sync_at: DateTime.utc_now(:second),
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

  When reactivating, checks that no other active integration exists for the same
  `(user_id, provider, provider_account_id)` to prevent a unique-constraint violation.
  """
  @spec toggle_active(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | :duplicate_account}
  def toggle_active(%CalendarIntegrationSchema{} = integration) do
    if integration.is_active do
      integration
      |> Changeset.change(%{is_active: false})
      |> Repo.update()
    else
      case check_reactivation_conflict(integration) do
        :ok ->
          integration
          |> Changeset.change(%{is_active: true})
          |> Repo.update()

        {:error, :duplicate_account} = err ->
          err
      end
    end
  end

  defp check_reactivation_conflict(%{provider_account_id: nil}), do: :ok

  defp check_reactivation_conflict(%{provider_account_id: ""}), do: :ok

  defp check_reactivation_conflict(integration) do
    case get_by_account_for_user(
           integration.user_id,
           integration.provider,
           integration.provider_account_id
         ) do
      {:ok, _existing} -> {:error, :duplicate_account}
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Updates a calendar integration - delegates to update/2.
  """
  @spec update_integration(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_integration(integration, attrs), to: __MODULE__, as: :update

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

  @doc "Updates the sync state fields for an integration."
  @spec update_sync_state(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_sync_state(integration, attrs) when is_map(attrs) do
    integration
    |> Changeset.change(attrs)
    |> Repo.update()
  end
end
