defmodule Tymeslot.Meetings.InvitationOccupyingIndexTest do
  @moduledoc """
  Pins the database side of single-use invitation links: the partial unique
  index on `meetings.invitation_id` must cover exactly the statuses that hold
  a slot, and must refuse a second live booking per invitation while letting
  history (cancelled, then rebooked) accumulate.
  """
  use Tymeslot.DataCase, async: true

  import Ecto.Query

  @moduletag :meetings
  @moduletag :database

  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  @index "meetings_invitation_id_occupying_index"

  test "the occupying index covers exactly MeetingState.occupying/0" do
    %{rows: [[indexdef]]} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [@index])

    statuses =
      ~r/'([a-z_]+)'/
      |> Regex.scan(indexdef, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.size(statuses) > 0
    assert statuses == MapSet.new(MeetingState.occupying(), &to_string/1)
  end

  describe "one live booking per invitation" do
    setup do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)
      now = DateTime.utc_now(:second)

      {1, [%{id: invitation_id}]} =
        Repo.insert_all(
          "meeting_type_invitations",
          [
            %{
              meeting_type_id: meeting_type.id,
              user_id: user.id,
              token_encrypted: "encrypted",
              token_hash: "hash-#{System.unique_integer([:positive])}",
              inserted_at: now,
              updated_at: now
            }
          ],
          returning: [:id]
        )

      %{invitation_id: invitation_id}
    end

    # Raw writes, because `MeetingSchema` has no `invitation_id` field yet.
    # Once the booking task adds it, build these with `insert(:meeting, ...)`.
    defp attach(invitation_id, status) do
      meeting = insert(:meeting, status: status)

      query = from(m in "meetings", where: m.id == type(^meeting.id, :binary_id))
      Repo.update_all(query, set: [invitation_id: invitation_id])
    end

    test "a second occupying meeting on one invitation is refused", %{invitation_id: id} do
      assert {1, _rows} = attach(id, :confirmed)

      assert_raise Postgrex.Error, ~r/#{@index}/, fn -> attach(id, :confirmed) end
    end

    test "a second cancelled meeting on one invitation is allowed", %{invitation_id: id} do
      assert {1, _rows} = attach(id, :confirmed)
      assert {1, _rows} = attach(id, :cancelled)
      assert {1, _rows} = attach(id, :cancelled)
    end

    test "cancelling the live booking lets the invitation be booked again", %{invitation_id: id} do
      assert {1, _rows} = attach(id, :confirmed)

      Repo.update_all(from(m in "meetings", where: m.invitation_id == ^id),
        set: [status: "cancelled"]
      )

      assert {1, _rows} = attach(id, :confirmed)
    end
  end
end
