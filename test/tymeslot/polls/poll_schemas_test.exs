defmodule Tymeslot.Polls.PollSchemasTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :polls

  alias Ecto.UUID
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

      assert %{title: _title, duration_minutes: _duration_minutes, timezone: _timezone} =
               errors_on(changeset)
    end

    test "holds a poll's proposed meeting to the same five-minute floor as a meeting type" do
      # Below five minutes is under the smallest slot interval the grid can be
      # drawn at, so it cannot be offered however it was created. A poll's
      # ceiling is higher than a meeting type's — a whole-day workshop is
      # exactly what a poll is for — but the floor is the same.
      for duration <- [0, 1, 4, 1441] do
        assert %{duration_minutes: _errors} = errors_on(poll_changeset(duration)),
               "accepted a #{duration}-minute poll"
      end

      for duration <- [5, 60, 1440] do
        refute Map.has_key?(errors_on(poll_changeset(duration)), :duration_minutes),
               "rejected a #{duration}-minute poll"
      end
    end
  end

  defp poll_changeset(duration_minutes) do
    PollSchema.creation_changeset(%PollSchema{}, %{
      user_id: 1,
      title: "x",
      duration_minutes: duration_minutes,
      timezone: "Etc/UTC"
    })
  end

  describe "PollTimeSlotSchema.changeset/2" do
    test "requires end after start" do
      start_time = ~U[2027-01-10 10:00:00Z]

      changeset =
        PollTimeSlotSchema.changeset(%PollTimeSlotSchema{}, %{
          poll_id: UUID.generate(),
          start_time: start_time,
          end_time: start_time
        })

      assert %{end_time: _end_time} = errors_on(changeset)
    end
  end

  describe "PollParticipantSchema.creation_changeset/2" do
    test "normalises email and generates token" do
      changeset =
        PollParticipantSchema.creation_changeset(%PollParticipantSchema{}, %{
          poll_id: UUID.generate(),
          name: "Ada",
          email: "  ADA@Example.COM "
        })

      assert changeset.valid?
      assert get_change(changeset, :email) == "ada@example.com"
      assert get_change(changeset, :token)
    end

    test "trims the name and rejects one that is only punctuation" do
      valid =
        PollParticipantSchema.creation_changeset(%PollParticipantSchema{}, %{
          poll_id: UUID.generate(),
          name: "  Ada Lovelace  ",
          email: "ada@example.com"
        })

      assert valid.valid?
      assert get_change(valid, :name) == "Ada Lovelace"

      invalid =
        PollParticipantSchema.creation_changeset(%PollParticipantSchema{}, %{
          poll_id: UUID.generate(),
          name: "<<>>",
          email: "ada@example.com"
        })

      refute invalid.valid?
      assert errors_on(invalid)[:name]
    end

    test "rejects an address the shared email validator refuses" do
      changeset =
        PollParticipantSchema.creation_changeset(%PollParticipantSchema{}, %{
          poll_id: UUID.generate(),
          name: "Ada",
          email: "ada@example"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:email]
    end

    # timezone and locale are convenience fields the page sends, not something a
    # guest types, so an unrecognised value is dropped rather than failing the
    # registration — but it must never reach the database.
    test "drops a timezone that is not a real IANA zone" do
      changeset =
        PollParticipantSchema.creation_changeset(%PollParticipantSchema{}, %{
          poll_id: UUID.generate(),
          name: "Ada",
          email: "ada@example.com",
          timezone: "Moon/Base"
        })

      assert changeset.valid?
      assert get_change(changeset, :timezone) == nil
    end

    test "keeps a real timezone and a supported locale" do
      changeset =
        PollParticipantSchema.creation_changeset(%PollParticipantSchema{}, %{
          poll_id: UUID.generate(),
          name: "Ada",
          email: "ada@example.com",
          timezone: "Europe/Tallinn",
          locale: "de"
        })

      assert changeset.valid?
      assert get_change(changeset, :timezone) == "Europe/Tallinn"
      assert get_change(changeset, :locale) == "de"
    end

    test "drops a locale the app does not support" do
      changeset =
        PollParticipantSchema.creation_changeset(%PollParticipantSchema{}, %{
          poll_id: UUID.generate(),
          name: "Ada",
          email: "ada@example.com",
          locale: "xx"
        })

      assert changeset.valid?
      assert get_change(changeset, :locale) == nil
    end
  end

  describe "PollVoteSchema.changeset/2" do
    test "accepts only known responses" do
      changeset =
        PollVoteSchema.changeset(%PollVoteSchema{}, %{
          poll_participant_id: UUID.generate(),
          poll_time_slot_id: UUID.generate(),
          response: :maybe
        })

      refute changeset.valid?
    end
  end
end
