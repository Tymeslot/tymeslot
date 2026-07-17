defmodule Tymeslot.Polls.PollSchemasTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit

  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema, PollTimeSlotSchema, PollVoteSchema}

  describe "PollSchema.creation_changeset/2" do
    test "valid attrs produce a valid changeset with generated token" do
      changeset =
        PollSchema.creation_changeset(%PollSchema{}, %{
          user_id: 1,
          title: "Q3 planning",
          duration_minutes: 30,
          timezone: "Europe/Berlin"
        })

      assert changeset.valid?
      assert get_change(changeset, :token)
      assert get_field(changeset, :status) == :open
    end

    test "requires title, duration and timezone" do
      changeset = PollSchema.creation_changeset(%PollSchema{}, %{user_id: 1})

      assert %{title: _, duration_minutes: _, timezone: _} = errors_on(changeset)
    end

    test "rejects non-positive durations" do
      changeset =
        PollSchema.creation_changeset(%PollSchema{}, %{
          user_id: 1,
          title: "x",
          duration_minutes: 0,
          timezone: "Etc/UTC"
        })

      assert %{duration_minutes: _} = errors_on(changeset)
    end
  end

  describe "PollTimeSlotSchema.changeset/2" do
    test "requires end after start" do
      start_time = ~U[2027-01-10 10:00:00Z]

      changeset =
        PollTimeSlotSchema.changeset(%PollTimeSlotSchema{}, %{
          poll_id: Ecto.UUID.generate(),
          start_time: start_time,
          end_time: start_time
        })

      assert %{end_time: _} = errors_on(changeset)
    end
  end

  describe "PollParticipantSchema.creation_changeset/2" do
    test "normalises email and generates token" do
      changeset =
        PollParticipantSchema.creation_changeset(%PollParticipantSchema{}, %{
          poll_id: Ecto.UUID.generate(),
          name: "Ada",
          email: "  ADA@Example.COM "
        })

      assert changeset.valid?
      assert get_change(changeset, :email) == "ada@example.com"
      assert get_change(changeset, :token)
    end
  end

  describe "PollVoteSchema.changeset/2" do
    test "accepts only known responses" do
      changeset =
        PollVoteSchema.changeset(%PollVoteSchema{}, %{
          poll_participant_id: Ecto.UUID.generate(),
          poll_time_slot_id: Ecto.UUID.generate(),
          response: :maybe
        })

      refute changeset.valid?
    end
  end
end
