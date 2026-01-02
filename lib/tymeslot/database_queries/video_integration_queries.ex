defmodule Tymeslot.DatabaseQueries.VideoIntegrationQueries do
  @moduledoc """
  Database queries for video integrations.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
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
    |> order_by([v], desc: v.is_default, asc: v.name)
  end

  @doc """
  Gets all active video integrations across all users.
  Used for health checks and monitoring.
  """
  @spec list_all_active() :: list(VideoIntegrationSchema.t())
  def list_all_active do
    VideoIntegrationSchema
    |> where([v], v.is_active == true)
    |> order_by([v], desc: v.is_default, asc: v.name)
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
    |> order_by([v], desc: v.is_default, asc: v.name)
    |> Repo.all()
    |> Enum.map(&VideoIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets the default video integration for a user.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get_default_for_user(integer()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def get_default_for_user(user_id) do
    result =
      VideoIntegrationSchema
      |> where([v], v.user_id == ^user_id and v.is_default == true and v.is_active == true)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}
    end
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
  Sets an integration as the default, unsetting any other defaults for the user.
  """
  @spec set_as_default(VideoIntegrationSchema.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, term()}
  def set_as_default(%VideoIntegrationSchema{} = integration) do
    Repo.transaction(fn ->
      # First, unset any existing defaults for this user
      VideoIntegrationSchema
      |> where([v], v.user_id == ^integration.user_id and v.is_default == true)
      |> Repo.update_all(set: [is_default: false])

      # Then set this one as default
      integration
      |> VideoIntegrationSchema.set_as_default_changeset()
      |> Repo.update!()
    end)
  end

  @doc """
  Toggles the active status of an integration.
  """
  @spec toggle_active(VideoIntegrationSchema.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_active(%VideoIntegrationSchema{} = integration) do
    # If we're deactivating the default, unset it as default
    changeset =
      if integration.is_active and integration.is_default do
        Changeset.change(integration, %{is_active: false, is_default: false})
      else
        Changeset.change(integration, %{is_active: !integration.is_active})
      end

    Repo.update(changeset)
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
