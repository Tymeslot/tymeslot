defmodule Tymeslot.Migrations.ConvertNaiveTimestampsToUtcTest do
  @moduledoc """
  Value-correctness regression for the `ConvertNaiveTimestampsToUtc`
  migration: it reinterprets naive `timestamp` columns as UTC via
  `col AT TIME ZONE 'UTC'`. This test seeds a known naive timestamp into a
  scratch table, runs the exact ALTER pattern the migration uses, and
  asserts the resulting `timestamptz` equals the same wall-clock value
  interpreted as UTC — the semantics the migration relies on for every
  Ecto-written row.

  See the migration's moduledoc for the documented limitation on the
  specific rows backfilled by raw SQL `NOW()` in two prior migrations, which
  this conversion cannot retroactively correct.

  Tests run non-async because they create a scratch table for the duration
  of the test.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Repo

  # Mirrors the migration's private `convert/4` helper exactly, applied to a
  # disposable scratch table instead of a live schema column.
  @convert_to_utc """
  ALTER TABLE naive_convert_scratch
  ALTER COLUMN happened_at TYPE timestamptz
  USING happened_at AT TIME ZONE 'UTC'
  """

  setup do
    Repo.query!("CREATE TEMP TABLE naive_convert_scratch (happened_at timestamp)")
    :ok
  end

  test "reinterprets a naive timestamp as the same instant in UTC" do
    Repo.query!("INSERT INTO naive_convert_scratch (happened_at) VALUES ('2026-03-15 14:30:00')")

    Repo.query!(@convert_to_utc)

    %{rows: [[value]]} = Repo.query!("SELECT happened_at FROM naive_convert_scratch")

    assert DateTime.truncate(value, :second) == ~U[2026-03-15 14:30:00Z]
  end

  test "preserves distinct wall-clock instants across multiple rows" do
    Repo.query!("""
    INSERT INTO naive_convert_scratch (happened_at) VALUES
      ('2026-01-01 00:00:00'),
      ('2026-06-30 23:59:59')
    """)

    Repo.query!(@convert_to_utc)

    %{rows: rows} =
      Repo.query!("SELECT happened_at FROM naive_convert_scratch ORDER BY happened_at")

    assert [~U[2026-01-01 00:00:00Z], ~U[2026-06-30 23:59:59Z]] ==
             Enum.map(rows, fn [value] -> DateTime.truncate(value, :second) end)
  end
end
