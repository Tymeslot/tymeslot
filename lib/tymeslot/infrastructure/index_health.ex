defmodule Tymeslot.Infrastructure.IndexHealth do
  @moduledoc """
  Boot-time report on indexes PostgreSQL has marked invalid.

  ## Why this exists

  Several migrations build their indexes with `CREATE INDEX CONCURRENTLY`, which
  cannot run inside a transaction. An interrupted build therefore leaves the
  half-built index behind marked `pg_index.indisvalid = false` rather than
  rolling it back. The migration fails without recording its version, so the
  migrator runs it again on the next boot, where `CREATE INDEX IF NOT EXISTS`
  sees an index of that name, skips the create, and records the version. The
  invalid index then stays forever.

  Nothing surfaces that. The planner simply ignores an invalid index, so the
  query it exists to serve falls back to a sequential scan on that installation
  alone, with no error anywhere. This check turns that silent failure into a
  log line naming the index, which is all an operator needs to run `REINDEX
  INDEX CONCURRENTLY` on it.

  ## What it is not

  A diagnostic must never become an outage. `check/0` therefore returns `:ok`
  whatever happens (an unreachable database, an ownership error, a pool
  timeout) and is started as a `:temporary` task off the boot path, so neither
  its failure nor its slowness can stop or delay the application starting. It
  never repairs anything either: rebuilding an index is minutes of I/O on a
  large table and is the operator's call, not a side effect of a restart.

  It is not behind a config flag, deliberately. It runs once, costs a single
  catalogue query, and logs nothing at all on a healthy database, so a flag
  would be dead configuration whose only real use is silencing the one signal
  the check exists to produce.
  """

  require Logger

  alias Tymeslot.Infrastructure.IndexHealthQueries

  @doc """
  Logs a warning for each invalid index and returns `:ok`.

  Called once at startup; safe to call by hand from a console.
  """
  @spec check() :: :ok
  def check do
    case list_invalid() do
      {:ok, []} ->
        :ok

      {:ok, invalid} ->
        Enum.each(invalid, &warn/1)

      {:error, reason} ->
        # Debug, not warning: the database being unreachable is loud enough
        # elsewhere, and a failed diagnostic is not itself news.
        Logger.debug("Invalid-index check did not run", reason: inspect(reason))
    end

    :ok
  end

  defp list_invalid do
    IndexHealthQueries.list_invalid()
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp warn(%{
         index: index,
         table: table,
         db_schema: db_schema,
         maintained_on_write: maintained_on_write
       }) do
    Logger.warning(
      "Invalid database index: the planner ignores it, so queries it should serve fall " <>
        "back to a sequential scan. Rebuild with REINDEX INDEX CONCURRENTLY.",
      index: index,
      table: table,
      db_schema: db_schema,
      maintained_on_write: maintained_on_write
    )
  end
end
