defmodule Tymeslot.Infrastructure.IndexHealthTest do
  @moduledoc """
  Covers the boot-time invalid-index report.

  The invalid index these tests are written against is a real one, produced the
  way PostgreSQL produces them: a `CREATE UNIQUE INDEX CONCURRENTLY` over a
  column that already holds duplicates fails part-way and leaves the half-built
  index behind marked `indisvalid = false`. Nothing here flips a catalogue flag
  by hand, so a check that only recognises a hand-made state would fail here.

  That forces the whole module outside the sandbox: `CREATE INDEX
  CONCURRENTLY` cannot run inside a transaction, which is the very reason the
  interrupted-build failure exists. Each test therefore checks a connection out
  with `sandbox: false` and cleans the probe table up itself.
  """

  use ExUnit.Case, async: false

  @moduletag :infrastructure
  @moduletag :database

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Infrastructure.IndexHealth
  alias Tymeslot.Infrastructure.IndexHealthQueries
  alias Tymeslot.Repo
  alias Tymeslot.Test.LogCapture

  @table "index_health_probe"
  @index "index_health_probe_value_index"

  setup do
    check_out!()
    drop_probe!()

    on_exit(fn ->
      # A fresh process: the connection this test held was checked back in when
      # it exited.
      check_out!()
      drop_probe!()
    end)

    :ok
  end

  describe "on a schema with no invalid index" do
    test "reports nothing" do
      assert IndexHealthQueries.list_invalid() == {:ok, []}
    end

    test "logs nothing" do
      LogCapture.attach()

      assert IndexHealth.check() == :ok

      refute_receive {:captured_log, %{meta: %{index: _reported}}}, 200
    end
  end

  describe "on a schema holding an index left invalid by a failed concurrent build" do
    setup do
      leave_invalid_index_behind!()
      :ok
    end

    test "names the index and its table" do
      assert {:ok, [invalid]} = IndexHealthQueries.list_invalid()

      assert invalid.index == @index
      assert invalid.table == @table
      assert invalid.db_schema == "public"

      # This build died on the duplicate during its *first* table scan, before
      # the index was marked ready, which is why the check cannot filter on
      # `indisready`: this is the commonest leftover of all, and it sits in the
      # state that "still being built" also occupies.
      assert invalid.maintained_on_write == false
    end

    test "logs one warning carrying the index as metadata" do
      LogCapture.attach()

      assert IndexHealth.check() == :ok

      # Matched on the `index` key rather than the level alone, so a warning
      # from a concurrently running async test cannot satisfy it.
      assert_receive {:captured_log, %{level: :warning, meta: %{index: _reported} = meta}}, 1_000
      assert meta.index == @index
      assert meta.table == @table
      assert meta.db_schema == "public"
    end

    test "stops reporting it once it is rebuilt" do
      Repo.query!("DROP INDEX #{@index}")
      Repo.query!("DELETE FROM #{@table} WHERE ctid <> (SELECT min(ctid) FROM #{@table})")
      Repo.query!("CREATE UNIQUE INDEX CONCURRENTLY #{@index} ON #{@table} (value)")

      assert IndexHealthQueries.list_invalid() == {:ok, []}
    end
  end

  describe "when the query cannot run at all" do
    # The two shapes a failure arrives in, because the check has to survive
    # both: a database that answers with an error, and one that is not there to
    # answer at all. Neither may reach the supervisor, or a diagnostic has
    # turned into an outage.

    test "returns :ok when the query comes back as an error" do
      test_process = self()

      # A bare `spawn`, not `Task.async`: a task inherits the caller's sandbox
      # ownership through `$callers`, which is exactly what this needs to not
      # have. Unowned, `Repo.query/3` answers `{:error,
      # %DBConnection.OwnershipError{}}`.
      spawn(fn -> send(test_process, {:checked, IndexHealth.check()}) end)

      assert_receive {:checked, :ok}, 1_000
    end

    test "returns :ok when the repo is not running" do
      # Process-local, so it dies with this test: every `Repo` call from here
      # on raises `RuntimeError`, the way they would if the check somehow ran
      # before the pool was up. Delete the `rescue` in `IndexHealth` and this
      # test fails with that raise rather than passing.
      Repo.put_dynamic_repo(:index_health_no_such_repo)

      assert IndexHealth.check() == :ok
    end
  end

  # A unique index over a column that already holds duplicates: PostgreSQL
  # detects the collision part-way through the concurrent build, fails the
  # statement, and leaves the index behind for good.
  defp leave_invalid_index_behind! do
    Repo.query!("CREATE TABLE #{@table} (value integer)")
    Repo.query!("INSERT INTO #{@table} (value) VALUES (1), (1)")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query("CREATE UNIQUE INDEX CONCURRENTLY #{@index} ON #{@table} (value)")
  end

  defp check_out! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end

  defp drop_probe! do
    Repo.query!("DROP TABLE IF EXISTS #{@table}")
  end
end
