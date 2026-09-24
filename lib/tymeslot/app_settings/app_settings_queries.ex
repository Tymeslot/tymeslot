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
  Closes the first-user admin bootstrap, returning `true` only to the caller
  that closed it.

  The claim is one conditional `UPDATE ... WHERE admin_bootstrapped_at IS
  NULL`. Two concurrent callers cannot both win: the second blocks on the row
  the first updated, and once the first commits, PostgreSQL re-evaluates the
  condition against the committed row and updates nothing. If the first
  rolls back, the second claims it instead. A missing singleton row is
  created first with `ON CONFLICT DO NOTHING`, which leaves the claim to the
  same `UPDATE`.
  """
  @spec claim_admin_bootstrap(module()) :: boolean()
  def claim_admin_bootstrap(repo \\ Repo) do
    now = DateTime.utc_now()

    repo.insert_all(AppSettingsSchema, [%{id: @singleton_id, inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    {claimed, _rows} =
      repo.update_all(
        from(s in AppSettingsSchema,
          where: s.id == @singleton_id and is_nil(s.admin_bootstrapped_at)
        ),
        set: [admin_bootstrapped_at: DateTime.truncate(now, :second)]
      )

    claimed == 1
  end
end
