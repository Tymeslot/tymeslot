defmodule Tymeslot.Infrastructure.IndexHealthQueries do
  @moduledoc """
  The catalogue query behind `Tymeslot.Infrastructure.IndexHealth`.

  Lives here rather than inline because every `Repo.*` call other than
  `transaction`, `rollback` and `preload` belongs in a `*_queries.ex` module
  (`CredoChecks.RepoCallBoundary`).
  """

  alias Tymeslot.Repo

  @type invalid_index :: %{
          db_schema: String.t(),
          table: String.t(),
          index: String.t(),
          maintained_on_write: boolean()
        }

  # Short on purpose: this runs on the boot path (as a supervised task beside
  # the rest of the tree) and is a diagnostic, so it must never be the thing
  # holding a slow database open.
  @timeout :timer.seconds(5)

  # An index PostgreSQL will not plan against is `indisvalid = false`. The two
  # further flags are what separate "broken and will stay broken" from the
  # states that clear themselves:
  #
  #   * `indislive = false` is only ever the tail of a `DROP INDEX
  #     CONCURRENTLY`: the index is already invisible to the planner *and* to
  #     writers, and disappears when the drop finishes or is retried. Warning
  #     about an index somebody is deliberately removing is noise, so it is
  #     excluded.
  #
  #   * `indisready` is *not* used as a filter, and that is the finding worth
  #     recording: it does not separate a failed build from a running one. A
  #     concurrent build passes through `(indisready = false, indisvalid =
  #     false)` while it does its first table scan and `(indisready = true,
  #     indisvalid = false)` while it validates, and an interruption in either
  #     window leaves the index sitting in that same state forever. Filtering
  #     `indisready = false` out would have hidden the easiest case of all to
  #     hit — a unique build that dies on a duplicate during its first scan.
  #     What the flag does say is how much the leftover costs, since a
  #     `indisready = true` index is still maintained on every write while
  #     buying no reads, so it is reported as metadata instead.
  #
  # The one state that genuinely is transient — a build running right now, on
  # this or another node — is excluded by `pg_stat_progress_create_index`
  # (PostgreSQL 12+; this project requires 14+), which carries exactly one row
  # per in-flight `CREATE INDEX` / `REINDEX` keyed by the index OID. That is
  # the purpose-built signal for "mid-build", where the catalogue flags are
  # ambiguous. Its one limitation is visibility: an unprivileged role sees only
  # its own backends' rows, so a build started by a *different* role could
  # still be reported. Tymeslot runs its migrations and its application under
  # one role, so that case does not arise here.
  #
  # `current_schemas(false)` keeps this to the schemas the application's own
  # search path resolves to, so `pg_catalog`, `pg_toast` and any unrelated
  # schema sharing the database are never reported.
  @invalid_indexes """
  SELECT namespace.nspname, tbl.relname, idx.relname, pgi.indisready
  FROM pg_index AS pgi
  JOIN pg_class AS idx ON idx.oid = pgi.indexrelid
  JOIN pg_class AS tbl ON tbl.oid = pgi.indrelid
  JOIN pg_namespace AS namespace ON namespace.oid = idx.relnamespace
  WHERE pgi.indisvalid = false
    AND pgi.indislive = true
    AND namespace.nspname = ANY (current_schemas(false))
    AND NOT EXISTS (
      SELECT 1
      FROM pg_stat_progress_create_index AS building
      WHERE building.index_relid = pgi.indexrelid
    )
  ORDER BY namespace.nspname, tbl.relname, idx.relname
  """

  @doc """
  Lists every index in the application's schemas that PostgreSQL has marked
  invalid and is not currently building.

  Returns `{:error, reason}` rather than raising when the query fails, so a
  caller on the boot path can degrade to a log line.
  """
  @spec list_invalid() :: {:ok, [invalid_index()]} | {:error, term()}
  def list_invalid do
    case Repo.query(@invalid_indexes, [], timeout: @timeout) do
      {:ok, %Postgrex.Result{rows: rows}} -> {:ok, Enum.map(rows, &to_invalid_index/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_invalid_index([db_schema, table, index, indisready]) do
    %{db_schema: db_schema, table: table, index: index, maintained_on_write: indisready}
  end
end
