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
  Gets every active integration for `provider`, across all users.

  Credentials are deliberately left encrypted: callers auditing plaintext
  columns such as `oauth_scope` have no use for them, and decrypting a whole
  table's tokens to read one plaintext field is work nobody asked for.
  """
  @spec list_active_by_provider(String.t()) :: [VideoIntegrationSchema.t()]
  def list_active_by_provider(provider) when is_binary(provider) do
    VideoIntegrationSchema
    |> exclude_deleted()
    |> where([v], v.provider == ^provider and v.is_active == true)
    |> order_by([v], asc: v.id)
    |> Repo.all()
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
  Finds an active video integration for a user and provider whose
  `provider_account_id` is NULL.

  This is the set the `unique_active_video_null_account_per_user` index covers,
  so it is what a reactivation of a legacy row has to be checked against.
  """
  @spec get_active_null_account_for_user(integer(), String.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def get_active_null_account_for_user(user_id, provider)
      when is_integer(user_id) and is_binary(provider) do
    VideoIntegrationSchema
    |> exclude_deleted()
    |> where(
      [v],
      v.user_id == ^user_id and v.provider == ^provider and
        is_nil(v.provider_account_id) and v.is_active == true
    )
    |> limit(1)
    |> Repo.one()
    |> null_account_result()
  end

  defp null_account_result(nil), do: {:error, :not_found}

  defp null_account_result(integration),
    do: {:ok, VideoIntegrationSchema.decrypt_credentials(integration)}

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
  Updates a video integration, leaving any outstanding `needs_reauth` flag in
  place.

  Background writers (token refresh, sync bookkeeping) must use this. To clear
  the flag, the caller must say so explicitly via `update_credentials/2`.
  """
  @spec update(VideoIntegrationSchema.t(), map()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%VideoIntegrationSchema{} = integration, attrs) do
    integration
    |> VideoIntegrationSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a video integration with credentials its owner has just supplied,
  clearing `needs_reauth`.

  Only reconnect paths may use this: an OAuth callback, or a credential form.
  See `Tymeslot.Integrations.Calendar.CalendarIntegrationQueries.update_credentials/2`
  for why this cannot be inferred from the changeset.
  """
  @spec update_credentials(VideoIntegrationSchema.t(), map()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_credentials(%VideoIntegrationSchema{} = integration, attrs) do
    integration
    |> VideoIntegrationSchema.changeset(attrs)
    |> Changeset.put_change(:needs_reauth, false)
    |> Repo.update()
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
  Deletes an integration by id, but only while it is still soft-deleted.

  Used by `Tymeslot.Workers.VideoIntegrationDisconnectWorker` to purge a row
  once its provider-side rooms have been cleaned up. The `deleted_at`
  predicate lives in the `WHERE` clause rather than in an application-level
  read-then-delete, so a reconnect (which nulls `deleted_at`) that commits
  after the worker last read the row cannot race the delete: either the row
  is still soft-deleted when this statement runs and it is removed, or it
  isn't and this is a no-op.

  Returns the number of rows deleted: `1` on a genuine purge, `0` when the
  row was reconnected (or already gone) before this ran.
  """
  @spec delete_if_still_deleted(integer()) :: non_neg_integer()
  def delete_if_still_deleted(id) do
    {count, _rows} =
      VideoIntegrationSchema
      |> where([v], v.id == ^id and not is_nil(v.deleted_at))
      |> Repo.delete_all()

    count
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
      |> VideoIntegrationSchema.activation_changeset(false)
      |> Repo.update()
    else
      case check_reactivation_conflict(integration) do
        :ok ->
          integration
          |> VideoIntegrationSchema.activation_changeset(true)
          |> Repo.update()

        {:error, :duplicate_account} = err ->
          err
      end
    end
  end

  # Every uniqueness index here is predicated on `is_active = true`, so
  # reactivating a row moves it *into* the index. A row whose account id is
  # NULL falls under the legacy-row index on `(user_id, provider)`, and one
  # whose account id is the empty string falls under the account index, because
  # `''` is not NULL. Waving both through returned `:ok` for exactly the rows
  # that contend, with no concurrency involved at all.
  defp check_reactivation_conflict(%{provider_account_id: nil} = integration) do
    case get_active_null_account_for_user(integration.user_id, integration.provider) do
      {:ok, _existing} -> {:error, :duplicate_account}
      {:error, :not_found} -> :ok
    end
  end

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
