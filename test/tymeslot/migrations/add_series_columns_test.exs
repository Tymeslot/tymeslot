defmodule Tymeslot.Migrations.AddSeriesColumnsTest do
  @moduledoc """
  Rolls the series migrations that run in a transaction down and back up
  against rows that predate them: the new constraints must accept every
  existing row, and `down` must restore the old shape.

  The meetings and participants migration builds its indexes concurrently, so
  it cannot run inside the sandbox; it is covered by rolling it back and
  forward by hand and by the dirty seed test.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @meeting_types 20_261_113_142_206
  @booking_payments 20_261_113_142_208

  test "meeting type settings survive a down and up over existing rows" do
    type = insert(:meeting_type)

    MigrationRunner.rerun!(@meeting_types)

    assert [[nil, 1, true]] =
             Repo.query!(
               "SELECT series_mode, series_interval, series_required FROM meeting_types WHERE id = $1",
               [type.id]
             ).rows

    assert_raise Postgrex.Error, ~r/meeting_types_series_check/, fn ->
      Repo.query!("UPDATE meeting_types SET series_mode = 'flexible' WHERE id = $1", [type.id])
    end

    Repo.query!(
      """
      UPDATE meeting_types SET series_mode = 'flexible', series_min_occurrences = 2,
        series_max_occurrences = 6 WHERE id = $1
      """,
      [type.id]
    )

    assert_raise Postgrex.Error, ~r/meeting_types_series_check/, fn ->
      Repo.query!("UPDATE meeting_types SET series_max_occurrences = 27 WHERE id = $1", [type.id])
    end
  end

  test "payments keep their meeting owner across a down and up" do
    payment = insert(:booking_payment)

    MigrationRunner.rerun!(@booking_payments)

    assert [[nil]] =
             Repo.query!("SELECT series_id FROM booking_payments WHERE id = $1", [
               UUID.dump!(payment.id)
             ]).rows

    MigrationRunner.down!(@booking_payments)

    assert [] =
             Repo.query!(
               "SELECT 1 FROM information_schema.columns WHERE table_name = 'booking_payments' AND column_name = 'series_id'"
             ).rows

    MigrationRunner.up!(@booking_payments)
  end
end
