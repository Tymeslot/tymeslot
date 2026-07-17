defmodule Tymeslot.Meetings.GuestSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :schema

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema

  describe "participant association" do
    test "creation_changeset casts participant_id" do
      changeset =
        GuestSchema.creation_changeset(%GuestSchema{}, %{
          email: "guest@example.com",
          meeting_id: UUID.generate(),
          participant_id: UUID.generate()
        })

      assert changeset.valid?
      assert changeset.changes.participant_id
    end

    test "a guest can be inserted with its owning participant" do
      participant = insert(:participant)

      assert {:ok, guest} =
               GuestQueries.insert_guest(%{
                 meeting_id: participant.meeting_id,
                 email: "plus-one@example.com",
                 participant_id: participant.id
               })

      assert guest.participant_id == participant.id
    end

    test "a guest without a participant stays valid (solo meetings)" do
      meeting = insert(:meeting)

      assert {:ok, guest} =
               GuestQueries.insert_guest(%{
                 meeting_id: meeting.id,
                 email: "solo@example.com"
               })

      assert guest.participant_id == nil
    end

    test "a participant's guests are reachable through the association" do
      participant = insert(:participant)

      {:ok, guest} =
        GuestQueries.insert_guest(%{
          meeting_id: participant.meeting_id,
          email: "plus-one@example.com",
          participant_id: participant.id
        })

      guest_id = guest.id

      assert %{guests: [%GuestSchema{id: ^guest_id}]} =
               Repo.preload(participant, :guests)
    end
  end
end
