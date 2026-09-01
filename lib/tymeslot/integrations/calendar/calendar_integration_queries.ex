defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationQueries do
  @moduledoc """
  Database queries for calendar integrations.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  # Postgres advisory-lock class id for the first-integration primary-election
  # race (see `acquire_primary_lock/1`). Advisory-lock class ids share a single
  # namespace across the whole database connection; other allocations are
  # `MeetingConflictQueries.@booking_limits_lock_class` (715_001) and the bare
  # `2` in `ProviderCalendarEventQueries`.
  @primary_lock_class 1

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
          |> where([c], c.is_active == true and c.needs_reauth == false)
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

  Returns:

    * `{:ok, integration}` — found and credentials readable
    * `{:error, :not_found}` — no row with that ID
    * `{:error, :requires_reencryption, integration}` — found but one or more
      encrypted credentials cannot be decrypted with the current keyring (e.g.
      after SECRET_KEY_BASE rotation). The raw integration (without decrypted
      virtual fields) is included so callers can flag `needs_reauth` without
      needing to re-query.

  Callers that previously only handled `{:ok, _}` and `{:error, :not_found}`
  must add a `{:error, :requires_reencryption, integration}` clause and route
  to `CalendarManagement.handle_reauth_required/1` (for background workers) or
  surface a reconnect prompt (for the web layer).
  """
  @spec get(integer()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :not_found}
          | {:error, :requires_reencryption, CalendarIntegrationSchema.t()}
  def get(id) do
    case Repo.get(CalendarIntegrationSchema, id) do
      nil ->
        {:error, :not_found}

      integration ->
        case CalendarIntegrationSchema.decryption_status(integration) do
          :ok -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
          :requires_reencryption -> {:error, :requires_reencryption, integration}
        end
    end
  end

  @doc """
  Gets a calendar integration by ID for a specific user.
  This is the secure version that checks user authorization.

  Returns:

    * `{:ok, integration}` — found and credentials readable
    * `{:error, :not_found}` — no row with that ID for this user
    * `{:error, :requires_reencryption, integration}` — found but one or more
      encrypted credentials cannot be decrypted with the current keyring (e.g.
      after SECRET_KEY_BASE rotation). The raw integration (without decrypted
      virtual fields) is included so callers can flag `needs_reauth` without
      needing to re-query.

  Callers that only need a two-outcome shape should use
  `CalendarManagement.fetch_integration_for_user/2`, which silently flags the
  integration on `:requires_reencryption` and collapses it to
  `{:error, :not_found}`.
  """
  @spec get_for_user(integer(), integer()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :not_found}
          | {:error, :requires_reencryption, CalendarIntegrationSchema.t()}
  def get_for_user(id, user_id) do
    result =
      CalendarIntegrationSchema
      |> where([c], c.id == ^id and c.user_id == ^user_id)
      |> Repo.one()

    case result do
      nil ->
        {:error, :not_found}

      integration ->
        case CalendarIntegrationSchema.decryption_status(integration) do
          :ok -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
          :requires_reencryption -> {:error, :requires_reencryption, integration}
        end
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
  Finds an active calendar integration for a user and provider whose
  `provider_account_id` is NULL.

  This is the set the `unique_active_calendar_null_account_per_user` index
  covers, so it is what a reactivation of a legacy row has to be checked
  against.
  """
  @spec get_active_null_account_for_user(integer(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_active_null_account_for_user(user_id, provider)
      when is_integer(user_id) and is_binary(provider) do
    CalendarIntegrationSchema
    |> where(
      [c],
      c.user_id == ^user_id and c.provider == ^provider and
        is_nil(c.provider_account_id) and c.is_active == true
    )
    |> limit(1)
    |> Repo.one()
    |> null_account_result()
  end

  defp null_account_result(nil), do: {:error, :not_found}
  defp null_account_result(integration), do: {:ok, integration}

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
  Updates a calendar integration, leaving any outstanding `needs_reauth` flag
  in place.

  Background writers (token refresh, sync bookkeeping) must use this. To clear
  the flag, the caller must say so explicitly via `update_credentials/2`.
  """
  @spec update(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%CalendarIntegrationSchema{} = integration, attrs) do
    integration
    |> CalendarIntegrationSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a calendar integration with credentials its owner has just supplied,
  clearing `needs_reauth`.

  Only reconnect paths may use this: an OAuth callback, or a CalDAV credential
  form. It cannot be inferred from the changeset instead, because credentials
  are encrypted with a fresh nonce per write (`Tymeslot.Security.Encryption`),
  so the ciphertext differs on every update whether or not the credential
  itself changed — "an encrypted field changed" carries no information about
  who supplied it. Inferring it meant the hourly background token refresh
  cleared reauth flags raised by unrelated failures, putting broken
  integrations back into the sync sweep every hour.
  """
  @spec update_credentials(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_credentials(%CalendarIntegrationSchema{} = integration, attrs) do
    integration
    |> CalendarIntegrationSchema.changeset(attrs)
    |> Changeset.put_change(:needs_reauth, false)
    |> Repo.update()
  end

  @doc """
  Marks the given calendars as unselected within an integration's `calendar_list`.

  Used when a previously-selected secondary calendar no longer exists on the
  provider (HTTP 404), so the sync worker stops attempting to fetch it on every
  run. Entries are matched on the provider calendar id; `calendar_list` is loaded
  from JSONB so entries carry string keys, with an atom-key fallback for any
  in-memory callers. A no-op (returns `{:ok, integration}`) when nothing matches.
  """
  @spec deselect_calendars(CalendarIntegrationSchema.t(), [String.t()]) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def deselect_calendars(%CalendarIntegrationSchema{} = integration, calendar_ids) do
    ids = MapSet.new(calendar_ids)

    updated_list =
      Enum.map(integration.calendar_list, fn cal ->
        if MapSet.member?(ids, cal.id) do
          %{cal | selected: false}
        else
          cal
        end
      end)

    integration
    |> CalendarIntegrationSchema.changeset(%{calendar_list: updated_list})
    |> Repo.update()
  end

  @doc """
  Removes the given paths from an integration's `calendar_paths`.

  Used when a CalDAV calendar collection no longer exists on the server
  (HTTP 404), so the sync worker stops fetching it on every run — the CalDAV
  counterpart to `deselect_calendars/2`. A no-op (returns `{:ok, integration}`)
  when nothing matches.
  """
  @spec remove_calendar_paths(CalendarIntegrationSchema.t(), [String.t()]) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def remove_calendar_paths(%CalendarIntegrationSchema{} = integration, paths) do
    remaining = Enum.reject(integration.calendar_paths, &(&1 in paths))

    integration
    |> CalendarIntegrationSchema.changeset(%{calendar_paths: remaining})
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
  Updates the last sync timestamp and clears any error. Also clears the
  `needs_reauth` flag — a successful sync proves the credentials are readable
  and valid, so the flag would otherwise become stale.
  """
  @spec mark_sync_success(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_sync_success(%CalendarIntegrationSchema{} = integration) do
    integration
    |> Changeset.change(%{
      last_sync_at: DateTime.utc_now(:second),
      sync_error: nil,
      needs_reauth: false
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
  Flags an integration as needing reauthentication — used when the stored
  credentials can no longer be decrypted. Also records a sync error so the
  dashboard banner and the sync log stay consistent.
  """
  @spec mark_needs_reauth(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_needs_reauth(%CalendarIntegrationSchema{} = integration, error_message) do
    integration
    |> Changeset.change(%{
      needs_reauth: true,
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
      |> CalendarIntegrationSchema.activation_changeset(false)
      |> Repo.update()
    else
      case check_reactivation_conflict(integration) do
        :ok ->
          integration
          |> CalendarIntegrationSchema.activation_changeset(true)
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
    if active_null_account_exists?(integration.user_id, integration.provider) do
      {:error, :duplicate_account}
    else
      :ok
    end
  end

  defp check_reactivation_conflict(integration) do
    if active_account_exists?(
         integration.user_id,
         integration.provider,
         integration.provider_account_id
       ) do
      {:error, :duplicate_account}
    else
      :ok
    end
  end

  # Existence-only checks: the reactivation conflict check never needs the
  # conflicting row's credentials, and decrypting them (as the equivalent
  # `get_*` lookups do) can raise on a row whose ciphertext no longer decrypts
  # under the current keyring — turning a refusal into a crash.
  defp active_null_account_exists?(user_id, provider) do
    CalendarIntegrationSchema
    |> where(
      [c],
      c.user_id == ^user_id and c.provider == ^provider and
        is_nil(c.provider_account_id) and c.is_active == true
    )
    |> Repo.exists?()
  end

  defp active_account_exists?(user_id, provider, provider_account_id) do
    CalendarIntegrationSchema
    |> where(
      [c],
      c.user_id == ^user_id and
        c.provider == ^provider and
        c.provider_account_id == ^provider_account_id and
        c.is_active == true
    )
    |> Repo.exists?()
  end

  @doc """
  Whether this integration belongs to this user.

  An ownership check and nothing more, for callers that act on an integration
  without needing to read it. `get_for_user/2` decrypts credentials and can
  answer `{:error, :requires_reencryption}`, neither of which a display-only
  change such as recolouring should have to care about or be blocked by.
  """
  @spec owned_by?(integer() | any(), integer() | any()) :: boolean()
  def owned_by?(id, user_id) when is_integer(id) and is_integer(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.id == ^id and c.user_id == ^user_id)
    |> Repo.exists?()
  end

  def owned_by?(_id, _user_id), do: false

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
  Acquires a transaction-scoped Postgres advisory lock keyed on the given
  user, so two concurrent first-integration inserts can't both observe
  `count_for_user/1 == 1`. Must be called from inside a `Repo.transaction/1`;
  the lock releases automatically at commit or rollback.
  """
  @spec acquire_primary_lock(integer()) :: :ok
  def acquire_primary_lock(user_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@primary_lock_class, user_id])
    :ok
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
