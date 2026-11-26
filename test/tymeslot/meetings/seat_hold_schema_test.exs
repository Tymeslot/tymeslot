defmodule Tymeslot.Meetings.SeatHoldSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :database

  alias Ecto.UUID
  alias Tymeslot.Meetings.SeatHoldQueries
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Repo

  defp hold_attrs(meeting, email) do
    %{
      meeting_id: meeting.id,
      start_time: DateTime.utc_now(:second),
      seats: 1,
      expires_at: DateTime.add(DateTime.utc_now(:second), 30, :minute),
      name: "Ann",
      email: email,
      timezone: "Europe/Zurich",
      locale: "en"
    }
  end

  defp insert_hold(meeting, email) do
    meeting |> hold_attrs(email) |> SeatHoldSchema.create_changeset() |> Repo.insert()
  end

  test "one live hold per email per meeting" do
    meeting = insert(:group_meeting)
    assert {:ok, _hold} = insert_hold(meeting, "Ann@example.com")

    assert {:error, changeset} = insert_hold(meeting, "ann@example.com")
    assert %{email: [_message]} = errors_on(changeset)
  end

  test "a released hold frees its email" do
    meeting = insert(:group_meeting)
    {:ok, first} = insert_hold(meeting, "Ann@example.com")
    assert %SeatHoldSchema{status: :released} = SeatHoldQueries.release(first.id, :expired)

    assert {:ok, _hold} = insert_hold(meeting, "ann@example.com")
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

    changeset =
      SeatHoldSchema.create_changeset(%{hold_attrs(meeting, "a@example.com") | seats: 0})

    refute changeset.valid?
    assert %{seats: [_message]} = errors_on(changeset)
  end

  test "a hold needs the contact details a participant needs" do
    meeting = insert(:group_meeting)

    changeset =
      meeting
      |> hold_attrs("not-an-email")
      |> Map.merge(%{timezone: nil, locale: "xx"})
      |> SeatHoldSchema.create_changeset()

    refute changeset.valid?

    assert %{timezone: [_timezone_error], locale: [_locale_error], email: [_email_error]} =
             errors_on(changeset)
  end

  test "a hold normalises its email like a participant" do
    meeting = insert(:group_meeting)
    {:ok, hold} = insert_hold(meeting, "  Ann@Example.com ")
    assert hold.email == "ann@example.com"
  end

  test "an unknown meeting is a changeset error" do
    attrs = %{hold_attrs(%{id: UUID.generate()}, "a@example.com") | meeting_id: UUID.generate()}

    assert {:error, changeset} = attrs |> SeatHoldSchema.create_changeset() |> Repo.insert()
    assert %{meeting_id: [_message]} = errors_on(changeset)
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
