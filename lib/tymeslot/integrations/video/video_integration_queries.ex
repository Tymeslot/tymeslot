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
    |> exclude_deleted()
    |> where([v], v.user_id == ^user_id and v.is_active == true)
    |> order_by([v], asc: v.name)
  end

  # Soft-deleted rows exist only so background cleanup can still authenticate
  # against the provider. They are never part of the user's integration surface,
  # so every listing and every by-provider or by-account lookup excludes them.
  # `get/1` and `get_for_user/2` deliberately do not: they take an explicit id,
  # and the cleanup worker reaches its dying integration through them.
  defp exclude_deleted(query), do: where(query, [v], is_nil(v.deleted_at))

  @doc """
  Gets all active video integrations across all users.
  Used for health checks and monitoring.
  """
  @spec list_all_active() :: list(VideoIntegrationSchema.t())
  def list_all_active do
    VideoIntegrationSchema
    |> exclude_deleted()
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
    |> exclude_deleted()
    |> where([v], v.user_id == ^user_id)
    |> order_by([v], desc: v.is_active, asc: v.name)
    |> Repo.all()
    |> Enum.map(&VideoIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets a single video integration by ID.
  WARNING: This function does not check user authorization.
  Use get_for_user/2 instead for secure access.

  Returns:

    * `{:ok, integration}` — found and credentials readable
    * `{:error, :not_found}` — no row with that ID
    * `{:error, :requires_reencryption, integration}` — found but one or more
      encrypted credentials cannot be decrypted with the current keyring (e.g.
      after SECRET_KEY_BASE rotation). The raw integration (without decrypted
      virtual fields) is included so callers can flag `needs_reauth` without
      needing to re-query.

  Callers must add a `{:error, :requires_reencryption, integration}` clause and
  route to `Tymeslot.Integrations.Video.handle_reauth_required/1` (for background
  workers) or surface a reconnect prompt (for the web layer).
  """
  @spec get(integer()) ::
          {:ok, VideoIntegrationSchema.t()}
          | {:error, :not_found}
          | {:error, :requires_reencryption, VideoIntegrationSchema.t()}
  def get(id) do
    case Repo.get(VideoIntegrationSchema, id) do
      nil ->
        {:error, :not_found}

      integration ->
        case VideoIntegrationSchema.decryption_status(integration) do
          :ok -> {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}
          :requires_reencryption -> {:error, :requires_reencryption, integration}
        end
    end
  end

  @doc """
  Gets a video integration by ID for a specific user.
  This is the secure version that checks user authorization.

  Returns:

    * `{:ok, integration}` — found and credentials readable
    * `{:error, :not_found}` — no row with that ID for this user
    * `{:error, :requires_reencryption, integration}` — found but one or more
      encrypted credentials cannot be decrypted with the current keyring (e.g.
      after SECRET_KEY_BASE rotation). The raw integration (without decrypted
      virtual fields) is included so callers can flag `needs_reauth` without
      needing to re-query.

  Callers must add a `{:error, :requires_reencryption, integration}` clause and
  route to `Tymeslot.Integrations.Video.handle_reauth_required/1` (for background
  workers) or surface a reconnect prompt (for the web layer).
  """
  @spec get_for_user(integer(), integer()) ::
          {:ok, VideoIntegrationSchema.t()}
          | {:error, :not_found}
          | {:error, :requires_reencryption, VideoIntegrationSchema.t()}
  def get_for_user(id, user_id) do
    result =
      VideoIntegrationSchema
      |> where([v], v.id == ^id and v.user_id == ^user_id)
      |> Repo.one()

    case result do
      nil ->
        {:error, :not_found}

      integration ->
        case VideoIntegrationSchema.decryption_status(integration) do
          :ok -> {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}
          :requires_reencryption -> {:error, :requires_reencryption, integration}
        end
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
      |> exclude_deleted()
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
      |> exclude_deleted()
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
      |> exclude_deleted()
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

  When the update replaces any encrypted credential field, clears the
  `needs_reauth` flag — the caller has supplied fresh credentials (via OAuth
  reconnect or a form), so the previous decryption-failure flag no longer applies.
  """
  @spec update(VideoIntegrationSchema.t(), map()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%VideoIntegrationSchema{} = integration, attrs) do
    integration
    |> VideoIntegrationSchema.changeset(attrs)
    |> maybe_clear_needs_reauth()
    |> Repo.update()
  end

  defp maybe_clear_needs_reauth(changeset) do
    if Enum.any?(
         VideoIntegrationSchema.encrypted_credential_fields(),
         &Map.has_key?(changeset.changes, &1)
       ) do
      Changeset.put_change(changeset, :needs_reauth, false)
    else
      changeset
    end
  end

  @doc """
  Flags an integration as needing reauthentication — used when the stored
  credentials can no longer be decrypted. Also records a sync error so the
  dashboard banner stays consistent.
  """
  @spec mark_needs_reauth(VideoIntegrationSchema.t(), String.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_needs_reauth(%VideoIntegrationSchema{} = integration, error_message) do
    integration
    |> Changeset.change(%{
      needs_reauth: true,
      sync_error: error_message
    })
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
  Marks an integration as disconnected without removing it.

  The row has to outlive the user's click: deleting provider-side rooms needs the
  OAuth credentials this row holds, and that work runs in a background job.
  Setting `is_active: false` at the same time is what keeps a soft-deleted row
  out of every unique index (they are all partial on `is_active = true`), so
  reconnecting the same account immediately afterwards cannot collide.

  `Tymeslot.Workers.VideoIntegrationDisconnectWorker` hard-deletes the row once
  the cleanup has drained.
  """
  @spec soft_delete(VideoIntegrationSchema.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete(%VideoIntegrationSchema{} = integration) do
    integration
    |> Changeset.change(%{
      deleted_at: DateTime.utc_now(:second),
      is_active: false
    })
    |> Repo.update()
  end

  @doc """
  Deletes every integration matching `(provider, provider_account_id)` regardless
  of the owning user. Used by provider-initiated revocation flows (e.g. the Zoom
  deauthorization webhook) where the only identifier we receive is the provider's
  account ID. Returns the number of rows deleted.
  """
  @spec delete_by_provider_account(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def delete_by_provider_account(provider, provider_account_id)
      when is_binary(provider) and is_binary(provider_account_id) and provider_account_id != "" do
    {count, _rows} =
      VideoIntegrationSchema
      |> where(
        [v],
        v.provider == ^provider and v.provider_account_id == ^provider_account_id
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Toggles the active status of an integration.

  When reactivating, checks that no other active integration exists for the same
  `(user_id, provider, provider_account_id)` to prevent a unique-constraint violation.
  """
  @spec toggle_active(VideoIntegrationSchema.t()) ::
          {:ok, VideoIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :duplicate_account | :not_found}
  # A soft-deleted row is on its way out and its rooms may already be gone;
  # reactivating it from a stale dashboard render would resurrect an integration
  # the user has disconnected.
  def toggle_active(%VideoIntegrationSchema{deleted_at: %DateTime{}}),
    do: {:error, :not_found}

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
    |> exclude_deleted()
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
    |> exclude_deleted()
    |> Repo.all()
    |> Enum.map(&VideoIntegrationSchema.decrypt_credentials/1)
  end
end
