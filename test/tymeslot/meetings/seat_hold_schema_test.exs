defmodule Tymeslot.Meetings.SeatHoldSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :database

  alias Ecto.UUID
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Repo

  defp hold_attrs(meeting, email) do
    %{
      meeting_id: meeting.id,
      start_time: DateTime.utc_now(:second),
      seats: 1,
      expires_at: DateTime.add(DateTime.utc_now(:second), 30, :minute),
      name: "Ann",
      email: email
    }
  end

  defp insert_hold(meeting, email) do
    meeting |> hold_attrs(email) |> SeatHoldSchema.create_changeset() |> Repo.insert()
  end

  test "one live hold per email per meeting" do
    meeting = insert(:group_meeting)
    assert {:ok, _} = insert_hold(meeting, "Ann@x.test")

    assert {:error, changeset} = insert_hold(meeting, "ann@x.test")
    assert %{email: [_]} = errors_on(changeset)
  end

  test "a released hold frees its email" do
    meeting = insert(:group_meeting)
    {:ok, first} = insert_hold(meeting, "Ann@x.test")
    {:ok, _} = first |> SeatHoldSchema.release_changeset(:abandoned) |> Repo.update()

    assert {:ok, _} = insert_hold(meeting, "ann@x.test")
  end

  test "released needs a reason" do
    hold = insert(:seat_hold)

    assert_raise Postgrex.Error, ~r/seat_holds_released_has_reason/, fn ->
      Repo.query!("UPDATE seat_holds SET status = 'released' WHERE id = $1", [
        UUID.dump!(hold.id)
      ])
    end
  end

  test "seats must be at least one" do
    meeting = insert(:group_meeting)
    changeset = SeatHoldSchema.create_changeset(%{hold_attrs(meeting, "a@x.test") | seats: 0})

    refute changeset.valid?
    assert %{seats: [_]} = errors_on(changeset)
  end

  test "release and convert refuse a hold that is not held" do
    hold = insert(:seat_hold)
    {:ok, released} = hold |> SeatHoldSchema.release_changeset(:expired) |> Repo.update()
    assert released.status == :released and released.released_reason == :expired

    assert %{status: [_]} = errors_on(SeatHoldSchema.convert_changeset(released, UUID.generate()))
    assert %{status: [_]} = errors_on(SeatHoldSchema.release_changeset(released, :failed))
  end

  test "converting a held hold records the participant" do
    hold = insert(:seat_hold)
    participant = insert(:participant, meeting: hold.meeting)

    {:ok, converted} = hold |> SeatHoldSchema.convert_changeset(participant.id) |> Repo.update()

    assert converted.status == :converted
    assert converted.participant_id == participant.id
  end

  test "deleting the meeting deletes its holds and keeps the payment" do
    meeting = insert(:group_meeting)
    hold = insert(:seat_hold, meeting: meeting)
    payment = insert(:booking_payment, meeting: meeting, seat_hold: hold, seat_payment: true)

    Repo.delete!(meeting)

    refute Repo.get(SeatHoldSchema, hold.id)
    reloaded = Repo.reload!(payment)
    assert reloaded.meeting_id == nil
    assert reloaded.seat_hold_id == nil
  end
end
