defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationQueries do
  @moduledoc """
  Database queries for calendar integrations.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @doc """
  Gets all active calendar integrations for a user, credentials left encrypted.

  Callers that read credentials go through
  `Calendar.Management.list_active_calendar_integrations/1`, which decrypts the
  readable rows and flags the rest for reconnection. Decrypting here would let
  one row that no longer decrypts raise for the whole listing.
  """
  @spec list_active_for_user(integer()) :: [CalendarIntegrationSchema.t()]
  def list_active_for_user(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id and c.is_active == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc """
  Whether the user has an active calendar integration whose provider is not
  one of `excluded_providers`.
  """
  @spec active_exists_except?(integer(), [String.t()]) :: boolean()
  def active_exists_except?(user_id, excluded_providers) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id and c.is_active == true)
    |> where([c], c.provider not in ^excluded_providers)
    |> Repo.exists?()
  end

  @doc "Of `user_ids`, those with at least one active calendar integration."
  @spec user_ids_with_active([integer()]) :: [integer()]
  def user_ids_with_active([]), do: []

  def user_ids_with_active(user_ids) when is_list(user_ids) do
    CalendarIntegrationSchema
    |> where([c], c.user_id in ^user_ids and c.is_active == true)
    |> distinct(true)
    |> select([c], c.user_id)
    |> Repo.all()
  end

  @doc """
  Gets all active calendar integrations across all users.
  Used for health checks and monitoring.

  Credentials are deliberately left encrypted: the sweep only needs the id,
  user and provider, and decrypting every row would let a single row that no
  longer decrypts (a changed key, corrupt bytes) abort the whole listing.
  """
  @spec list_all_active() :: list(CalendarIntegrationSchema.t())
  def list_all_active do
    active_query()
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc """
  The query for every active integration across all users. For other
  queries modules to join against.
  """
  @spec active_query() :: Ecto.Query.t()
  def active_query, do: where(CalendarIntegrationSchema, [c], c.is_active == true)

  @doc """
  The next page of active integrations not waiting to be reconnected, in id
  order: at most `limit` of them with an id above `after_id` (`0` for the
  first page). Credentials are left encrypted, as for `list_all_active/0`.

  Each page is its own short query, so a caller can act on one page (enqueue
  jobs, say) before reading the next without holding a transaction open
  across the whole walk.
  """
  @spec list_active_page(non_neg_integer(), pos_integer()) :: [CalendarIntegrationSchema.t()]
  def list_active_page(after_id, limit) do
    CalendarIntegrationSchema
    |> where([c], c.is_active == true and c.needs_reauth == false and c.id > ^after_id)
    |> order_by([c], asc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets all calendar integrations for a user (including inactive).

  A row whose credentials no longer decrypt is returned as stored, so the
  owner still sees it listed and can reconnect it.
  """
  @spec list_all_for_user(integer()) :: [CalendarIntegrationSchema.t()]
  def list_all_for_user(user_id) do
    user_id
    |> list_all_for_user_encrypted()
    |> Enum.map(&decrypt_if_readable/1)
  end

  @doc """
  Like `list_all_for_user/1`, but leaves the credentials encrypted. The caller
  decrypts each row itself (`CalendarIntegrationSchema.decrypt_credentials/1`)
  where it can handle a failure.
  """
  @spec list_all_for_user_encrypted(integer()) :: [CalendarIntegrationSchema.t()]
  def list_all_for_user_encrypted(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], desc: c.is_active, asc: c.name)
    |> Repo.all()
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
  to `Calendar.Management.handle_reauth_required/1` (for background workers) or
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
  `Calendar.Management.fetch_integration_for_user/2`, which silently flags the
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

  This and the two account lookups below find the row a reconnection is
  about to overwrite, so a row whose credentials no longer decrypt is
  returned as stored rather than raising.
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
      integration -> {:ok, decrypt_if_readable(integration)}
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
      integration -> {:ok, decrypt_if_readable(integration)}
    end
  end

  @doc """
  Whether a user other than `user_id` has a calendar of `provider` on the
  external account `provider_account_id` that still holds a token, active or
  not.
  """
  @spec account_held_by_other_user?(String.t(), String.t(), integer()) :: boolean()
  def account_held_by_other_user?(provider, provider_account_id, user_id)
      when is_binary(provider) and is_binary(provider_account_id) and is_integer(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.provider == ^provider and c.provider_account_id == ^provider_account_id)
    |> where([c], c.user_id != ^user_id)
    |> where([c], not is_nil(c.refresh_token_encrypted) or not is_nil(c.access_token_encrypted))
    |> Repo.exists?()
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
      integration -> {:ok, decrypt_if_readable(integration)}
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
  clearing `needs_reauth` and the `sync_error` that explained it. A failure
  after the reconnect that records no reason of its own (a refused bulk
  deletion, or any failure of a provider whose sync workers do not write
  one) would otherwise show the old reason on the card again.

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
    |> Changeset.put_change(:sync_error, nil)
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
  Clears the reconnection flag and the error that accompanied it, for a sync
  cycle that read from the provider.

  A cycle that completed disproves every condition that sets the flag: rejected
  credentials, a booking calendar deleted at the provider, a CalDAV integration
  with no calendar selected. Left set, the flag keeps the integration out of
  booking indefinitely (`BookingIntegrationResolver.booking_target?/1` requires
  `needs_reauth: false`) however well it is syncing, and nothing but the owner
  reconnecting by hand ever clears it.

  This is deliberately narrower than it looks: a *successful token refresh*
  must not clear it, because a fresh token says nothing about a deleted
  calendar — see `Calendar.Auth.Tokens.maybe_clear_sync_error/2`. Only a sync
  that actually read the calendar carries the proof.

  Ecto skips the statement entirely when neither field has changed, so the
  overwhelming majority of cycles cost nothing here.
  """
  @spec clear_reauth_flag(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def clear_reauth_flag(%CalendarIntegrationSchema{} = integration) do
    integration
    |> Changeset.change(%{sync_error: nil, needs_reauth: false})
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
    # A sync can outlive its integration: an error recorded after the row was
    # deleted is an `{:error, changeset}`, not a crash of the job reporting it.
    |> Repo.update(stale_error_field: :id)
  end

  @doc "Whether the calendar integration `id` still exists."
  @spec exists?(integer()) :: boolean()
  def exists?(id), do: Repo.exists?(from(i in CalendarIntegrationSchema, where: i.id == ^id))

  @doc """
  Flags an integration as needing reauthentication and records `message` as
  its sync error, so the dashboard banner and the sync log stay consistent.

  Whether this is a new flag is decided by the row, not by `integration`,
  which may be stale: of two concurrent flaggers, exactly one sees
  `newly_flagged?` true. Only a new flag stamps `reauth_flagged_at`, so
  re-flagging is not counted again by `count_reauth_flagged_by_provider/2`.
  `{:error, :not_found}` when the row is gone.
  """
  @spec flag_needs_reauth(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t(), newly_flagged? :: boolean()}
          | {:error, :not_found}
  def flag_needs_reauth(%CalendarIntegrationSchema{id: id} = integration, message) do
    now = DateTime.truncate(Clock.utc_now(), :second)
    row = where(CalendarIntegrationSchema, id: ^id)
    flag = [needs_reauth: true, sync_error: message, updated_at: now]

    case Repo.update_all(where(row, needs_reauth: false), set: [reauth_flagged_at: now] ++ flag) do
      {1, _rows} ->
        {:ok, struct(integration, [reauth_flagged_at: now] ++ flag), true}

      {0, _rows} ->
        case Repo.update_all(row, set: flag) do
          {1, _rows} -> {:ok, struct(integration, flag), false}
          {0, _rows} -> {:error, :not_found}
        end
    end
  end

  @doc """
  Counts the integrations newly flagged `needs_reauth` within `[from, to)`,
  per provider, whether or not the flag has since been cleared.
  """
  @spec count_reauth_flagged_by_provider(DateTime.t(), DateTime.t()) ::
          %{String.t() => pos_integer()}
  def count_reauth_flagged_by_provider(%DateTime{} = from, %DateTime{} = to) do
    CalendarIntegrationSchema
    |> where([c], c.reauth_flagged_at >= ^from and c.reauth_flagged_at < ^to)
    |> group_by([c], c.provider)
    |> select([c], {c.provider, count(c.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The integration's row as it stands now, credentials left encrypted, or nil
  once it is gone. For a change decided under a lock, which must act on the
  stored state rather than on a struct read before the lock was taken.
  """
  @spec reload(CalendarIntegrationSchema.t()) :: CalendarIntegrationSchema.t() | nil
  def reload(%CalendarIntegrationSchema{id: id}), do: Repo.get(CalendarIntegrationSchema, id)

  @doc """
  Sets the integration inactive, never the other way round: the write forces
  `is_active` to false whatever the struct says, so a stale struct cannot turn
  a pause into a no-op or a reactivation.
  """
  @spec deactivate(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Changeset.t()}
  def deactivate(%CalendarIntegrationSchema{} = integration) do
    integration
    |> Changeset.change()
    |> Changeset.force_change(:is_active, false)
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
  @spec check_reactivation_conflict(CalendarIntegrationSchema.t()) ::
          :ok | {:error, :duplicate_account}
  def check_reactivation_conflict(%{provider_account_id: nil} = integration) do
    if active_null_account_exists?(integration.user_id, integration.provider) do
      {:error, :duplicate_account}
    else
      :ok
    end
  end

  def check_reactivation_conflict(integration) do
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

  defp decrypt_if_readable(integration) do
    case CalendarIntegrationSchema.decryption_status(integration) do
      :ok -> CalendarIntegrationSchema.decrypt_credentials(integration)
      :requires_reencryption -> integration
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
  Whether the caller runs inside a transaction, so a write can leave what
  must wait for the commit (dropping a cache) to the caller that commits.
  """
  @spec in_transaction?() :: boolean()
  def in_transaction?, do: Repo.in_transaction?()

  @doc """
  Holds the user's row `FOR KEY SHARE` for the rest of the transaction, so the
  account cannot be deleted under it: an account deletion locks that row
  `FOR UPDATE` before its cascade reaches the user's calendars and meeting
  types, and waits here, or this waits for it. `false` when the user is gone.

  Must be called from inside a `Repo.transaction/1`.
  """
  @spec lock_owner(integer()) :: boolean()
  def lock_owner(user_id) do
    Repo.exists?(from(u in UserSchema, where: u.id == ^user_id, lock: "FOR KEY SHARE"))
  end

  @doc """
  Locks the user's profile row, then every calendar integration row of theirs,
  for the rest of the transaction. Every change that can move the user's
  primary calendar takes it first (create, toggle, pause, delete, reconnect),
  so those changes run one at a time per user and always lock in the same
  order. A user without a profile has no primary to move, so locking nothing
  there is harmless.

  Must be called from inside a `Repo.transaction/1`.
  """
  @spec lock_user_profile_and_integrations(integer()) :: :ok
  def lock_user_profile_and_integrations(user_id) do
    _locked_profile =
      Repo.one(from(p in ProfileSchema, where: p.user_id == ^user_id, lock: "FOR UPDATE"))

    _locked_integration_ids =
      Repo.all(
        from(ci in CalendarIntegrationSchema,
          where: ci.user_id == ^user_id,
          order_by: ci.id,
          select: ci.id,
          lock: "FOR UPDATE"
        )
      )

    :ok
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
    |> CalendarIntegrationSchema.bookkeeping_changeset(attrs)
    |> Repo.update()
  end
end
