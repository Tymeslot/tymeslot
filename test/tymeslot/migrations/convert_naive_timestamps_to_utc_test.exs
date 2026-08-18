defmodule Tymeslot.Migrations.ConvertNaiveTimestampsToUtcTest do
  @moduledoc """
  Value-correctness regression for
  `20260702180346_convert_naive_timestamps_to_utc`, which reinterprets naive
  `timestamp` columns as UTC via `col AT TIME ZONE 'UTC'`.

  The migration is driven directly: `down` puts the columns back to naive
  `timestamp` (the pre-migration shape) and `up` converts them again, so the
  assertions are about the conversion that shipped rather than a copy of its
  SQL. The decisive property is that the wall-clock value survives the round
  trip and comes back as the same instant in UTC.

  See the migration's moduledoc for the documented limitation on the specific
  rows backfilled by raw SQL `NOW()` in two prior migrations, which this
  conversion cannot retroactively correct.

  Runs non-async because it rewrites live column types for the duration of
  the test; the sandbox rolls the DDL back with everything else.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_702_180_346

  test "reinterprets a naive timestamp as the same instant in UTC" do
    email = "naive-convert@example.com"
    insert(:user, email: email)
    stamp!(email, ~U[2026-03-15 14:30:00Z])

    # Back to the pre-migration shape: the instant becomes a bare wall clock.
    MigrationRunner.down!(@version)
    assert column_type("users", "inserted_at") == "timestamp without time zone"
    assert inserted_at(email) == ~N[2026-03-15 14:30:00]

    MigrationRunner.up!(@version)
    assert column_type("users", "inserted_at") == "timestamp with time zone"
    assert inserted_at(email) == ~U[2026-03-15 14:30:00Z]
  end

  test "preserves distinct wall-clock instants across multiple rows" do
    early = "naive-early@example.com"
    late = "naive-late@example.com"

    insert(:user, email: early)
    insert(:user, email: late)
    stamp!(early, ~U[2026-01-01 00:00:00Z])
    stamp!(late, ~U[2026-06-30 23:59:59Z])

    MigrationRunner.rerun!(@version)

    assert inserted_at(early) == ~U[2026-01-01 00:00:00Z]
    assert inserted_at(late) == ~U[2026-06-30 23:59:59Z]
  end

  test "converts updated_at and the inserted_at-only tables too" do
    MigrationRunner.down!(@version)

    assert column_type("users", "updated_at") == "timestamp without time zone"
    assert column_type("webhook_events", "inserted_at") == "timestamp without time zone"

    MigrationRunner.up!(@version)

    assert column_type("users", "updated_at") == "timestamp with time zone"
    assert column_type("webhook_events", "inserted_at") == "timestamp with time zone"
  end

  # Written past the schema: the column is naive for part of each test, so the
  # value has to go in as raw SQL rather than through a changeset.
  defp stamp!(email, %DateTime{} = at) do
    Repo.query!("UPDATE users SET inserted_at = $1 WHERE email = $2", [at, email])
  end

  # Naive on the way down, aware on the way up, and only whole seconds are the
  # point — so both shapes are cut to the second before comparison.
  defp inserted_at(email) do
    %{rows: [[value]]} =
      Repo.query!("SELECT inserted_at FROM users WHERE email = $1", [email])

    to_second(value)
  end

  defp to_second(%DateTime{} = value), do: DateTime.truncate(value, :second)
  defp to_second(%NaiveDateTime{} = value), do: NaiveDateTime.truncate(value, :second)

  defp column_type(table, column) do
    %{rows: [[type]]} =
      Repo.query!(
        """
        SELECT data_type
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    type
  end
end
