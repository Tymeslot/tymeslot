defmodule Tymeslot.BookingSeries.SeriesSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :payments

  import Ecto.Changeset, only: [change: 2, check_constraint: 3]

  alias Ecto.UUID
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        mode: :recurring,
        frequency: :weekly,
        interval: 1,
        occurrences_count: 4,
        attendee_name: "Sam Booker",
        attendee_email: "sam@example.com"
      },
      overrides
    )
  end

  # Bypasses the changeset's own required-field checks so the database
  # constraint is what refuses the row.
  defp insert_raw(overrides) do
    %SeriesSchema{}
    |> change(Map.merge(attrs(), overrides))
    |> check_constraint(:frequency, name: :booking_series_rule_check)
    |> check_constraint(:occurrences_count, name: :booking_series_count_check)
    |> Repo.insert()
  end

  test "a series needs a frequency in recurring mode" do
    assert {:error, changeset} = insert_raw(%{frequency: nil})
    assert {"is invalid", _meta} = changeset.errors[:frequency]

    assert {:error, changeset} = SeriesQueries.insert(attrs(%{frequency: nil}))
    assert changeset.errors[:frequency]

    assert {:error, changeset} = SeriesQueries.insert(attrs(%{interval: 5}))
    assert changeset.errors[:frequency]
  end

  test "a recurring series needs an interval" do
    assert {:error, changeset} = SeriesQueries.insert(attrs(%{interval: nil}))
    assert changeset.errors[:frequency]

    assert {:error, changeset} = insert_raw(%{interval: nil})
    assert changeset.errors[:frequency]
  end

  describe "meeting type series settings" do
    defp set_type_series!(type, sets) do
      {sql, params} =
        sets
        |> Enum.with_index(2)
        |> Enum.map_reduce([], fn {{col, val}, i}, acc -> {"#{col} = $#{i}", acc ++ [val]} end)

      Repo.query!("UPDATE meeting_types SET #{Enum.join(sql, ", ")} WHERE id = $1", [
        type.id | params
      ])
    end

    test "a recurring type needs a frequency" do
      type = insert(:meeting_type)

      assert_raise Postgrex.Error, ~r/meeting_types_series_check/, fn ->
        set_type_series!(type,
          series_mode: "recurring",
          series_min_occurrences: 2,
          series_max_occurrences: 6
        )
      end

      set_type_series!(type,
        series_mode: "recurring",
        series_frequency: "weekly",
        series_min_occurrences: 2,
        series_max_occurrences: 6
      )
    end

    test "the minimum may not exceed the maximum" do
      type = insert(:meeting_type)

      assert_raise Postgrex.Error, ~r/meeting_types_series_check/, fn ->
        set_type_series!(type,
          series_mode: "flexible",
          series_min_occurrences: 6,
          series_max_occurrences: 3
        )
      end

      set_type_series!(type,
        series_mode: "flexible",
        series_min_occurrences: 3,
        series_max_occurrences: 6
      )
    end
  end

  test "a flexible series needs no rule" do
    assert {:ok, series} =
             SeriesQueries.insert(attrs(%{mode: :flexible, frequency: nil, interval: nil}))

    assert series.mode == :flexible
    assert series.frequency == nil
    assert {:ok, _uuid} = UUID.cast(series.uid)
  end

  test "the count is bounded" do
    for count <- [1, 27] do
      assert {:error, changeset} = SeriesQueries.insert(attrs(%{occurrences_count: count}))
      assert changeset.errors[:occurrences_count], "count #{count} was accepted"
    end

    for count <- [2, 26] do
      assert {:ok, %{occurrences_count: ^count}} =
               SeriesQueries.insert(attrs(%{occurrences_count: count}))
    end
  end

  test "the uid is unique and finds the series" do
    {:ok, series} = SeriesQueries.insert(attrs())

    assert {:ok, found} = SeriesQueries.get_by_uid(series.uid)
    assert found.id == series.id
    assert {:error, :not_found} = SeriesQueries.get_by_uid("not-a-uuid")
    assert {:error, :not_found} = SeriesQueries.get_by_uid(UUID.generate())

    assert {:error, changeset} = SeriesQueries.insert(attrs(%{uid: series.uid}))
    assert {"has already been taken", _meta} = changeset.errors[:uid]
  end

  test "get_for_organizer scopes to the owner" do
    user = insert(:user)
    other = insert(:user)
    {:ok, series} = SeriesQueries.insert(attrs(%{organizer_user_id: user.id}))

    assert {:ok, %{id: id}} = SeriesQueries.get_for_organizer(series.id, user.id)
    assert id == series.id
    assert {:error, :not_found} = SeriesQueries.get_for_organizer(series.id, other.id)
  end

  test "occurrences list in series order, meetings and participants alike" do
    {:ok, series} = SeriesQueries.insert(attrs())
    {:ok, other} = SeriesQueries.insert(attrs())

    m2 = insert(:meeting, series_id: series.id, series_position: 2)
    m1 = insert(:meeting, series_id: series.id, series_position: 1)
    insert(:meeting, series_id: other.id, series_position: 1)

    assert Enum.map(SeriesQueries.list_occurrences(series), & &1.id) == [m1.id, m2.id]
    assert Enum.map(SeriesQueries.list_occurrences(series.id), & &1.series_position) == [1, 2]
  end

  test "lock re-reads the series inside a transaction" do
    {:ok, series} = SeriesQueries.insert(attrs())

    assert {:ok, locked} = Repo.transaction(fn -> SeriesQueries.lock(series) end)
    assert locked.id == series.id
  end

  test "cancel_changeset stamps cancelled_at" do
    {:ok, series} = SeriesQueries.insert(attrs())
    now = DateTime.utc_now()

    assert {:ok, cancelled} = series |> SeriesSchema.cancel_changeset(now) |> Repo.update()
    assert cancelled.cancelled_at == now
  end

  test "cancelled_at is not castable on create" do
    {:ok, series} = SeriesQueries.insert(attrs(%{cancelled_at: DateTime.utc_now()}))
    assert series.cancelled_at == nil
  end

  describe "payments" do
    test "a payment belongs to a meeting or a series, never both" do
      {:ok, series} = SeriesQueries.insert(attrs())
      meeting = insert(:meeting)

      assert_raise Ecto.ConstraintError, ~r/booking_payments_single_owner_check/, fn ->
        insert(:booking_payment, meeting_id: meeting.id, series_id: series.id)
      end

      assert %{series_id: sid, meeting_id: nil} = insert(:booking_payment, series_id: series.id)
      assert sid == series.id
      assert %{series_id: nil} = insert(:booking_payment, meeting_id: meeting.id)
    end

    test "one payment per series" do
      {:ok, series} = SeriesQueries.insert(attrs())
      insert(:booking_payment, series_id: series.id)

      assert_raise Ecto.ConstraintError, ~r/booking_payments_series_id_index/, fn ->
        insert(:booking_payment, series_id: series.id)
      end
    end
  end

  test "deleting a series keeps its meetings" do
    {:ok, series} = SeriesQueries.insert(attrs())
    meeting = insert(:meeting, series_id: series.id, series_position: 1)

    Repo.delete!(series)

    survivor = Repo.get!(MeetingSchema, meeting.id)
    assert survivor.series_id == nil
  end
end
