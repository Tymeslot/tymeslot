defmodule Tymeslot.BookingSeries.FirstStartBackfillTest do
  @moduledoc """
  Drives `20261114160210_add_first_start_at_to_booking_series` itself: each
  existing series gets the earliest start of its sessions or seats,
  cancelled ones included, and a series with none keeps `NULL`.

  The migration module is loaded from `priv` and run through `Ecto.Migrator`;
  see `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :bookings

  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_114_160_210

  @early ~U[2026-03-02 10:00:00Z]
  @late ~U[2026-03-09 10:00:00Z]

  defp series(host), do: insert(:booking_series, organizer_user: nil, organizer_user_id: host.id)

  defp meeting(host, start, attrs \\ []) do
    insert(
      :meeting,
      [
        organizer_user_id: host.id,
        start_time: start,
        end_time: DateTime.add(start, 30, :minute),
        duration: 30
      ] ++ attrs
    )
  end

  defp first_start_at(series), do: Repo.get!(SeriesSchema, series.id).first_start_at

  test "backfills each series from its earliest session or seat" do
    host = insert(:user)
    group_host = insert(:user)
    one_to_one = series(host)
    group = series(group_host)
    empty = series(host)

    meeting(host, @early,
      status: "cancelled",
      series_id: one_to_one.id,
      series_position: 1
    )

    meeting(host, @late, series_id: one_to_one.id, series_position: 2)

    for {start, position} <- [{@late, 2}, {@early, 1}] do
      insert(:participant,
        meeting: meeting(group_host, start),
        series_id: group.id,
        series_position: position
      )
    end

    MigrationRunner.rerun!(@version)

    assert DateTime.compare(first_start_at(one_to_one), @early) == :eq
    assert DateTime.compare(first_start_at(group), @early) == :eq
    assert first_start_at(empty) == nil
  end
end
