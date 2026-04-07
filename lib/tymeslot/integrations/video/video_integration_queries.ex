defmodule Tymeslot.Integrations.Video.VideoIntegrationQueries do
  @moduledoc """
  Database queries for video integrations.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  @doc """
  Gets all active video integrations for a user.
  """
  @spec list_active_for_user(integer()) :: [VideoIntegrationSchema.t()]
  def list_active_for_user(user_id) do
    user_id
    |> base_active_query()
    |> Repo.all()
    |> Enum.map(&VideoIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets all active video integrations for a user without decrypting credentials.
  Use this in UI contexts that only need id/name/provider.
  """
  @spec list_active_for_user_public(integer()) :: [VideoIntegrationSchema.t()]
  def list_active_for_user_public(user_id) do
    user_id
    |> base_active_query()
    |> Repo.all()
  end

  # Private helper for shared query pattern
  defp base_active_query(user_id) do
    VideoIntegrationSchema
    |> where([v], v.user_id == ^user_id and v.is_active == true)
    |> order_by([v], asc: v.name)
  end

  @doc """
  Gets all active video integrations across all users.
  Used for health checks and monitoring.
  """
  @spec list_all_active() :: list(VideoIntegrationSchema.t())
  def list_all_active do
    VideoIntegrationSchema
    |> where([v], v.is_active == true)
    |> order_by([v], asc: v.name)
    |> Repo.all()
    |> Enum.map(&VideoIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets all video integrations for a user (including inactive).
  """
  @spec list_all_for_user(integer()) :: [VideoIntegrationSchema.t()]
  def list_all_for_user(user_id) do
    VideoIntegrationSchema
    |> where([v], v.user_id == ^user_id)
    |> order_by([v], desc: v.is_active, asc: v.name)
    |> Repo.all()
    |> Enum.map(&VideoIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets a single video integration by ID.
  WARNING: This function does not check user authorization.
  Use get_for_user/2 instead for secure access.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get(integer()) :: {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(VideoIntegrationSchema, id) do
      nil -> {:error, :not_found}
      integration -> {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Gets a video integration by ID for a specific user.
  This is the secure version that checks user authorization.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get_for_user(integer(), integer()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def get_for_user(id, user_id) do
    result =
      VideoIntegrationSchema
      |> where([v], v.id == ^id and v.user_id == ^user_id)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Gets an active video integration by provider for a specific user.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get_by_provider_for_user(integer(), String.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def get_by_provider_for_user(user_id, provider) do
    result =
      VideoIntegrationSchema
      |> where([v], v.user_id == ^user_id and v.provider == ^provider and v.is_active == true)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Finds an active video integration by provider and account ID for a user.
  """
  @spec get_by_account_for_user(integer(), String.t(), String.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def get_by_account_for_user(user_id, provider, provider_account_id)
      when is_integer(user_id) and is_binary(provider) and is_binary(provider_account_id) do
    result =
      VideoIntegrationSchema
      |> where(
        [v],
        v.user_id == ^user_id and
          v.provider == ^provider and
          v.provider_account_id == ^provider_account_id and
          v.is_active == true
      )
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Finds any video integration (active or inactive) by provider and account ID for a user.
  Used to detect inactive duplicates before creating a new row.
  """
  @spec get_any_by_account_for_user(integer(), String.t(), String.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def get_any_by_account_for_user(user_id, provider, provider_account_id)
      when is_integer(user_id) and is_binary(provider) and is_binary(provider_account_id) do
    result =
      VideoIntegrationSchema
      |> where(
        [v],
        v.user_id == ^user_id and
          v.provider == ^provider and
          v.provider_account_id == ^provider_account_id
      )
      |> order_by([v], desc: v.is_active)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Creates a new video integration.
  """
  @spec create(map()) :: {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %VideoIntegrationSchema{}
    |> VideoIntegrationSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a video integration.
  """
  @spec update(VideoIntegrationSchema.t(), map()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%VideoIntegrationSchema{} = integration, attrs) do
    integration
    |> VideoIntegrationSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a video integration.
  """
  @spec delete(VideoIntegrationSchema.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%VideoIntegrationSchema{} = integration) do
    Repo.delete(integration)
  end

  @doc """
  Toggles the active status of an integration.

  When reactivating, checks that no other active integration exists for the same
  `(user_id, provider, provider_account_id)` to prevent a unique-constraint violation.
  """
  @spec toggle_active(VideoIntegrationSchema.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | :duplicate_account}
  def toggle_active(%VideoIntegrationSchema{} = integration) do
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
  Counts video integrations for a user.
  """
  @spec count_for_user(integer()) :: non_neg_integer()
  def count_for_user(user_id) do
    VideoIntegrationSchema
    |> where([v], v.user_id == ^user_id)
    |> select([v], count(v.id))
    |> Repo.one() || 0
  end

  @doc """
  Gets all video integrations (for consistency checks).
  Used by data consistency service.
  """
  @spec list_all() :: list(VideoIntegrationSchema.t())
  def list_all do
    VideoIntegrationSchema
    |> Repo.all()
    |> Enum.map(&VideoIntegrationSchema.decrypt_credentials/1)
  end
end
