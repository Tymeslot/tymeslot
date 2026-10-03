defmodule Tymeslot.Meetings.ParticipantSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :schema

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings.ParticipantSchema

  describe "creation_changeset/2" do
    test "valid attrs produce a valid changeset with a generated management token" do
      meeting = insert(:meeting)

      changeset =
        ParticipantSchema.creation_changeset(%ParticipantSchema{}, %{
          meeting_id: meeting.id,
          name: "Ada Lovelace",
          email: "ada@example.com",
          timezone: "Europe/London"
        })

      assert changeset.valid?
      assert %{management_token: token} = changeset.changes
      assert byte_size(token) == 43
    end

    test "requires meeting_id, name, email and timezone" do
      changeset = ParticipantSchema.creation_changeset(%ParticipantSchema{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.meeting_id
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.email
      assert "can't be blank" in errors.timezone
    end

    test "rejects an invalid email like meetings reject attendee_email" do
      changeset =
        ParticipantSchema.creation_changeset(%ParticipantSchema{}, %{
          meeting_id: UUID.generate(),
          name: "Ada Lovelace",
          email: "not-an-email",
          timezone: "Europe/London"
        })

      refute changeset.valid?
      assert %{email: [_message]} = errors_on(changeset)
    end

    test "normalises the email" do
      changeset =
        ParticipantSchema.creation_changeset(%ParticipantSchema{}, %{
          meeting_id: UUID.generate(),
          name: "Ada Lovelace",
          email: "  Ada@Example.COM ",
          timezone: "Europe/London"
        })

      assert changeset.changes.email == "ada@example.com"
    end

    test "keeps a caller-supplied management token" do
      changeset =
        ParticipantSchema.creation_changeset(%ParticipantSchema{}, %{
          meeting_id: UUID.generate(),
          name: "Ada Lovelace",
          email: "ada@example.com",
          timezone: "Europe/London",
          management_token: "explicit-token"
        })

      assert changeset.changes.management_token == "explicit-token"
    end

    test "rejects an unsupported locale" do
      changeset =
        ParticipantSchema.creation_changeset(%ParticipantSchema{}, %{
          meeting_id: UUID.generate(),
          name: "Ada Lovelace",
          email: "ada@example.com",
          timezone: "Europe/London",
          locale: "xx"
        })

      assert "is not a supported locale" in errors_on(changeset).locale
    end
  end

  describe "cancel_changeset/2" do
    test "stamps cancelled_at" do
      cancelled_at = DateTime.utc_now(:second)
      changeset = ParticipantSchema.cancel_changeset(%ParticipantSchema{}, cancelled_at)

      assert changeset.changes.cancelled_at == cancelled_at
    end
  end

  describe "live?/1" do
    test "true for a participant without cancelled_at" do
      assert ParticipantSchema.live?(%ParticipantSchema{cancelled_at: nil})
    end

    test "false for a cancelled participant" do
      refute ParticipantSchema.live?(%ParticipantSchema{
               cancelled_at: DateTime.utc_now(:second)
             })
    end
  end
end
