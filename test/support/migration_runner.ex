defmodule Tymeslot.Test.MigrationRunner do
  @moduledoc """
  Runs the real migration modules from `priv` inside a test's sandbox
  transaction.

  A migration test that pastes the migration's SQL into a module attribute
  proves nothing about the migration: the copy and the original drift apart in
  silence, and the test keeps passing over the stale copy. This helper loads
  the migration file that ships and drives it through `Ecto.Migrator`, so the
  assertions are about the code a self-hoster will actually run.

  ## Using it

      alias Tymeslot.Test.MigrationRunner

      @version 20_260_716_094_322

      test "backfills the column" do
        insert(:meeting, status: "reschedule_requested")

        MigrationRunner.rerun!(@version)

        ...
      end

  Pick the entry point by what the migration can do twice:

  | Function | Use when |
  |---|---|
  | `rerun!/2` | The migration is reversible: it goes `down` and straight back `up`, so `up` meets the pre-migration schema, exactly as it did on a real database. |
  | `replay!/2` | `down/0` is irreversible or destructive, and `up/0` is safe to re-apply over the migrated schema (a pure data backfill, or one written with `IF NOT EXISTS`). Only the recorded version is dropped. |
  | `up!/2`, `down!/2`, `forget!/2` | One step at a time, when a test needs to assert between them. |

  ## Sandbox constraints

  Three of these bit during development; none of them is obvious from the
  `Ecto.Migrator` docs.

  * **`migration_lock: false` is mandatory**, and this module always passes it.
    `Ecto.Migrator` runs every migration inside `Task.async/1`, while the
    migration lock has already opened a transaction on the connection. The
    sandbox owns exactly one connection, so the task queues behind a lock that
    can never be released and the call dies once the pool queue times out.

  * **The test database is already fully migrated**, so `Ecto.Migrator.up/4`
    short-circuits to `:already_up`. The version has to come back off the
    ledger first, which is what `rerun!/2` and `replay!/2` do.

  * **Everything is rolled back with the test transaction**, the
    `schema_migrations` bookkeeping included, so a converted test leaves the
    database exactly as it found it. Migrations that set
    `@disable_ddl_transaction` are the exception and are not supported here:
    their DDL escapes the sandbox.

  ## Repos

  Core migrations need no options. SaaS migrations record their versions in
  `schema_migrations_saas`, which only `Tymeslot.SaasRepo`'s config knows
  about, while the sandbox connection belongs to `Tymeslot.Repo`. Naming both
  gets the bookkeeping and the connection right:

      MigrationRunner.replay!(@version, repo: Tymeslot.SaasRepo, dynamic_repo: Tymeslot.Repo)

  `Tymeslot.SaasRepo` is not compiled in the Core repo, hence the option
  rather than a named preset here.
  """

  import ExUnit.Assertions

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator

  @type version :: integer()
  @type opts :: [
          repo: Ecto.Repo.t(),
          dynamic_repo: Ecto.Repo.t(),
          path: Path.t(),
          log: Logger.level() | boolean()
        ]

  @doc """
  Rolls the migration back and applies it again.

  The preferred entry point: `up/0` runs against the pre-migration schema, so
  the test exercises the migration the way a real database met it.
  """
  @spec rerun!(version(), opts()) :: :ok
  def rerun!(version, opts \\ []) do
    down!(version, opts)
    up!(version, opts)
  end

  @doc """
  Drops the recorded version and applies the migration again, without rolling
  it back first.

  For migrations whose `down/0` raises, or whose `down/0` would destroy the
  data under test. The schema is still the migrated one, so `up/0` has to be
  safe to re-apply.
  """
  @spec replay!(version(), opts()) :: :ok
  def replay!(version, opts \\ []) do
    forget!(version, opts)
    up!(version, opts)
  end

  @doc """
  Applies the migration's `up/0`, failing if it was already applied.
  """
  @spec up!(version(), opts()) :: :ok
  def up!(version, opts \\ []) do
    case migrate(:up, version, opts) do
      :ok ->
        :ok

      :already_up ->
        flunk("""
        Migration #{version} is already applied, so `up/0` never ran.

        The test database is migrated before the suite starts. Use
        `rerun!/2` (down, then up) or `replay!/2` (forget the version, then
        up) instead of calling `up!/2` on its own.
        """)
    end
  end

  @doc """
  Applies the migration's `down/0`, failing if it was not applied.
  """
  @spec down!(version(), opts()) :: :ok
  def down!(version, opts \\ []) do
    case migrate(:down, version, opts) do
      :ok ->
        :ok

      :already_down ->
        flunk("Migration #{version} is not applied, so `down/0` never ran.")
    end
  end

  @doc """
  Deletes the migration's row from the schema-migrations ledger, leaving the
  schema untouched.

  Rolled back with the test, like everything else here.
  """
  @spec forget!(version(), opts()) :: :ok
  def forget!(version, opts \\ []) do
    source = migration_source(repo(opts))

    SQL.query!(data_repo(opts), "DELETE FROM #{source} WHERE version = $1", [version])

    :ok
  end

  @doc """
  Loads the migration module for `version` from `priv`.

  Exposed for tests that need to reach the module itself; `rerun!/2` and
  friends call it for you.
  """
  @spec module(version(), opts()) :: module()
  def module(version, opts \\ []) do
    path = migration_path!(version, opts)

    case :persistent_term.get({__MODULE__, path}, nil) do
      nil ->
        module = compile!(path)
        :persistent_term.put({__MODULE__, path}, module)
        module

      module ->
        module
    end
  end

  defp migrate(direction, version, opts) do
    apply(Migrator, direction, [
      repo(opts),
      version,
      module(version, opts),
      migrator_opts(opts)
    ])
  end

  # `migration_lock: false` is the load-bearing option; see the moduledoc.
  defp migrator_opts(opts) do
    Keyword.merge(
      [migration_lock: false, log: false],
      Keyword.take(opts, [:dynamic_repo, :log, :log_migrations_sql])
    )
  end

  # Compiling the file is how the module gets loaded at all: `priv` is not on
  # the code path. The result is cached because a second test loading the same
  # migration would otherwise warn about redefining the module.
  defp compile!(path) do
    modules = path |> Code.compile_file() |> Enum.map(&elem(&1, 0))

    case Enum.find(modules, &migration?/1) do
      nil -> flunk("#{path} does not define an Ecto.Migration")
      module -> module
    end
  end

  defp migration?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__migration__, 0)
  end

  defp migration_path!(version, opts) do
    directory = Keyword.get_lazy(opts, :path, fn -> Migrator.migrations_path(repo(opts)) end)

    case Path.wildcard(Path.join(directory, "#{version}_*.exs")) do
      [path] -> path
      [] -> flunk("no migration #{version} in #{directory}")
      paths -> flunk("several migrations claim version #{version}: #{Enum.join(paths, ", ")}")
    end
  end

  defp migration_source(repo) do
    Keyword.get(repo.config(), :migration_source, "schema_migrations")
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Tymeslot.Repo)

  defp data_repo(opts), do: Keyword.get(opts, :dynamic_repo, repo(opts))
end
