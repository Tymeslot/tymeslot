defmodule Tymeslot.AppSettings.AppSettingsQueries do
  @moduledoc """
  Query interface for the singleton `app_settings` row.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.AppSettings.AppSettingsSchema
  alias Tymeslot.Repo

  @singleton_id 1

  # Key for the transaction-scoped advisory lock that serialises the
  # first-user admin bootstrap. Any constant works as long as nothing else
  # takes the same one; this is the ASCII of "tsadmbst".
  @admin_bootstrap_lock_key 0x747361646D627374

  @doc """
  Returns the singleton settings row. The row is seeded by the migration, so
  this always returns a struct — never `nil` — except during the brief window
  before the migration has run, in which case it falls back to a struct with
  all overrides set to `nil` (i.e. "no overrides, use config defaults").
  """
  @spec get_settings(module()) :: AppSettingsSchema.t()
  def get_settings(repo \\ Repo) do
    repo.get(AppSettingsSchema, @singleton_id) || %AppSettingsSchema{id: @singleton_id}
  rescue
    # The read can fail at boot before the migration has created the table, or
    # because the database is briefly unreachable. We fall back to a struct
    # with all overrides nil ("use config defaults") so the app still starts —
    # but a failure here silently drops any DB overrides until the next
    # `AppSettings.load!/0`, so log it loudly to distinguish a genuine failure
    # from the legitimate "no overrides configured" case (which never reaches
    # this rescue — it returns the seeded row above).
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("app_settings read failed; falling back to config defaults",
        reason: inspect(error)
      )

      %AppSettingsSchema{id: @singleton_id}
  end

  @doc """
  Updates the singleton settings row with the given attributes.

  The read and write are wrapped in a serialisable transaction with a
  `FOR UPDATE` row lock, preventing two concurrent admin saves from
  overwriting each other's changes.

  A `guard` function runs *inside* the same transaction, after the
  changeset has been applied to the locked row but before the commit. It
  receives the merged settings struct (the exact state about to be committed)
  and must return `:ok` to allow the commit or `{:error, reason}` to roll it
  back with that reason. Evaluating the guard against the row-locked, merged
  state — rather than against pre-transaction application state — closes the
  TOCTOU window where two concurrent saves could each individually pass a
  check yet jointly violate it (e.g. both disabling the last auth path).
  """
  @spec update_settings(map(), (AppSettingsSchema.t() -> :ok | {:error, term()}), module()) ::
          {:ok, AppSettingsSchema.t()} | {:error, Changeset.t() | term()}
  def update_settings(attrs, guard, repo \\ Repo)
      when is_map(attrs) and is_function(guard, 1) do
    repo.transaction(fn ->
      query = from(s in AppSettingsSchema, where: s.id == @singleton_id, lock: "FOR UPDATE")
      settings = repo.one(query) || %AppSettingsSchema{id: @singleton_id}

      changeset = AppSettingsSchema.changeset(settings, attrs)

      with {:ok, merged} <- Changeset.apply_action(changeset, :update),
           :ok <- guard.(merged),
           {:ok, updated} <- repo.insert_or_update(changeset) do
        updated
      else
        {:error, %Changeset{} = changeset} -> repo.rollback(changeset)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  @doc """
  Takes the transaction-scoped advisory lock that serialises the first-user
  admin bootstrap. Blocks until any other transaction holding it ends, and is
  released when the caller's transaction commits or rolls back, so it must be
  called inside one.
  """
  @spec lock_admin_bootstrap(module()) :: :ok
  def lock_admin_bootstrap(repo \\ Repo) do
    repo.query!("SELECT pg_advisory_xact_lock($1)", [@admin_bootstrap_lock_key])
    :ok
  end

  @doc """
  Whether the first-user admin bootstrap has already closed.
  """
  @spec admin_bootstrapped?(module()) :: boolean()
  def admin_bootstrapped?(repo \\ Repo) do
    repo.exists?(
      from(s in AppSettingsSchema,
        where: s.id == @singleton_id and not is_nil(s.admin_bootstrapped_at)
      )
    )
  end

  @doc """
  Records that the first-user admin bootstrap has closed, creating the
  singleton row if it is missing. Keeps an existing timestamp.
  """
  @spec mark_admin_bootstrapped(module()) :: :ok
  def mark_admin_bootstrapped(repo \\ Repo) do
    now = DateTime.utc_now(:second)

    repo.insert!(%AppSettingsSchema{id: @singleton_id, admin_bootstrapped_at: now},
      on_conflict:
        from(s in AppSettingsSchema,
          update: [set: [admin_bootstrapped_at: coalesce(s.admin_bootstrapped_at, ^now)]]
        ),
      conflict_target: :id
    )

    :ok
  end
end
