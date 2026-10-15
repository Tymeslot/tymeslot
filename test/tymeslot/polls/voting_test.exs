defmodule Tymeslot.Polls.VotingTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :unit
  @moduletag :polls

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantQueries, PollSchema, Voting}
  alias Tymeslot.Workers.EmailWorker

  describe "request_link/2" do
    test "creates an unconfirmed participant and emails them their link" do
      poll = insert(:poll)

      assert :ok = Voting.request_link(poll, %{name: "Alice", email: "Alice@Example.com "})

      participant = PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com")
      assert participant.name == "Alice"
      assert is_binary(participant.token) and participant.token != ""
      assert participant.confirmed_at == nil
      assert %DateTime{} = participant.link_sent_at

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_participant_link", "participant_id" => participant.id}
      )

      assert PollParticipantQueries.count_confirmed(poll.id) == 0
      assert PollParticipantQueries.count_unconfirmed(poll.id) == 1
    end

    test "an unconfirmed participant counts nowhere on the poll" do
      poll = insert(:poll)
      :ok = Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})

      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
      assert loaded.participants == []
    end

    test "an address already on the poll gets its link again, unchanged and without a duplicate" do
      poll = insert(:poll)
      first = insert(:poll_participant, poll: poll, name: "Alice", email: "alice@example.com")

      assert :ok = Voting.request_link(poll, %{name: "Mallory", email: " ALICE@example.com "})

      again = PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com")
      assert again.id == first.id
      assert again.name == "Alice"
      assert again.token == first.token
      assert PollParticipantQueries.count_confirmed(poll.id) == 1
      assert PollParticipantQueries.count_unconfirmed(poll.id) == 0

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_participant_link", "participant_id" => first.id}
      )
    end

    test "sends a link at most once per address within the resend window" do
      poll = insert(:poll)

      :ok = Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})
      :ok = Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})
      :ok = Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})

      assert length(link_jobs()) == 1
    end

    test "sends the link again once the resend window has passed" do
      poll = insert(:poll)

      participant =
        insert(:poll_participant,
          poll: poll,
          email: "alice@example.com",
          link_sent_at: DateTime.add(DateTime.utc_now(), -11, :minute)
        )

      :ok = Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})

      assert [%{args: %{"participant_id" => id}}] = link_jobs()
      assert id == participant.id
    end

    test "a request for an expired unconfirmed address brings its link back to life" do
      poll = insert(:poll)

      participant =
        insert(:poll_participant,
          poll: poll,
          email: "alice@example.com",
          confirmed_at: nil,
          link_sent_at: DateTime.add(DateTime.utc_now(), -3, :day)
        )

      assert Voting.get_participant(poll, participant.token) == nil

      :ok = Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})

      assert %{id: id} = Voting.get_participant(poll, participant.token)
      assert id == participant.id
    end

    test "returns {:error, :voting_closed} when the poll is not open" do
      poll = insert(:poll, status: :cancelled)

      assert {:error, :voting_closed} =
               Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})
    end

    test "returns the changeset for an invalid address and sends nothing" do
      poll = insert(:poll)

      assert {:error, %Ecto.Changeset{}} =
               Voting.request_link(poll, %{name: "Alice", email: "not-an-address"})

      assert {:error, %Ecto.Changeset{}} = Voting.request_link(poll, %{name: "Alice"})
      assert link_jobs() == []
    end

    test "returns {:error, :poll_full} for a new address once the confirmed cap is reached" do
      poll = insert(:poll)
      insert_list(PollSchema.max_participants(), :poll_participant, poll: poll)

      assert {:error, :poll_full} =
               Voting.request_link(poll, %{name: "Late", email: "late@example.com"})
    end

    test "unconfirmed requests do not fill the poll" do
      poll = insert(:poll)
      insert_list(PollSchema.max_participants() - 1, :poll_participant, poll: poll)
      insert_list(5, :poll_participant, poll: poll, confirmed_at: nil, link_sent_at: now())

      assert :ok = Voting.request_link(poll, %{name: "Real", email: "real@example.com"})
    end

    test "returns {:error, :too_many_requests} once too many links are out unconfirmed" do
      poll = insert(:poll)

      insert_list(PollSchema.max_unconfirmed_participants(), :poll_participant,
        poll: poll,
        confirmed_at: nil,
        link_sent_at: now()
      )

      assert {:error, :too_many_requests} =
               Voting.request_link(poll, %{name: "Late", email: "late@example.com"})
    end

    test "expired unconfirmed requests do not count against that limit" do
      poll = insert(:poll)

      insert_list(PollSchema.max_unconfirmed_participants(), :poll_participant,
        poll: poll,
        confirmed_at: nil,
        link_sent_at: DateTime.add(now(), -3, :day)
      )

      assert :ok = Voting.request_link(poll, %{name: "Real", email: "real@example.com"})
    end
  end

  describe "get_participant/2" do
    test "returns the poll's participant for their token, with votes loaded" do
      poll = insert(:poll)
      slot = insert(:poll_time_slot, poll: poll)
      participant = insert(:poll_participant, poll: poll)
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      assert %{id: id, votes: [%{response: :yes}]} =
               Voting.get_participant(poll, participant.token)

      assert id == participant.id
    end

    test "returns nil for a token that belongs to a different poll" do
      poll = insert(:poll)
      insert(:poll_participant, poll: poll)
      other_participant = insert(:poll_participant)

      assert Voting.get_participant(poll, other_participant.token) == nil
    end

    test "returns nil for an unknown token" do
      poll = insert(:poll)

      assert Voting.get_participant(poll, "no-such-token") == nil
    end

    test "returns nil for a token that is not a string" do
      poll = insert(:poll)

      assert Voting.get_participant(poll, nil) == nil
      assert Voting.get_participant(poll, %{"token" => "x"}) == nil
    end
  end

  describe "cast_votes/3" do
    setup do
      poll = insert(:poll)
      start_a = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
      start_b = DateTime.add(start_a, 2, :hour)

      slot_a =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_a,
          end_time: DateTime.add(start_a, 1, :hour)
        )

      slot_b =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_b,
          end_time: DateTime.add(start_b, 1, :hour)
        )

      participant = insert(:poll_participant, poll: poll)
      poll = %{poll | time_slots: [slot_a, slot_b]}

      %{poll: poll, slot_a: slot_a, slot_b: slot_b, participant: participant}
    end

    test "persists votes, stamps voted_at, and broadcasts", ctx do
      %{poll: poll, slot_a: slot_a, slot_b: slot_b, participant: participant} = ctx
      Polls.subscribe(poll.id)

      assert {:ok, _participant} =
               Voting.cast_votes(poll, participant.token, %{
                 slot_a.id => "yes",
                 slot_b.id => "if_need_be"
               })

      votes =
        PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).votes

      assert length(votes) == 2

      responses = Map.new(votes, &{&1.poll_time_slot_id, &1.response})
      assert responses[slot_a.id] == :yes
      assert responses[slot_b.id] == :if_need_be

      assert %DateTime{} =
               PollParticipantQueries.get_by_poll_and_token(
                 participant.poll_id,
                 participant.token
               ).voted_at

      assert_receive {:poll_updated, poll_id}
      assert poll_id == poll.id
    end

    test "replaces an existing vote for the same slot", ctx do
      %{poll: poll, slot_a: slot_a, participant: participant} = ctx

      assert {:ok, _first} = Voting.cast_votes(poll, participant.token, %{slot_a.id => "yes"})

      assert {:ok, _replacement} =
               Voting.cast_votes(poll, participant.token, %{slot_a.id => "no"})

      assert [vote] =
               PollParticipantQueries.get_by_poll_and_token(
                 participant.poll_id,
                 participant.token
               ).votes

      assert vote.poll_time_slot_id == slot_a.id
      assert vote.response == :no
    end

    test "accepts atom responses and the hyphenated if-need-be form", ctx do
      %{poll: poll, slot_a: slot_a, slot_b: slot_b, participant: participant} = ctx

      assert {:ok, _result} =
               Voting.cast_votes(poll, participant.token, %{
                 slot_a.id => :yes,
                 slot_b.id => "if-need-be"
               })

      responses =
        Map.new(
          PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).votes,
          &{&1.poll_time_slot_id, &1.response}
        )

      assert responses[slot_a.id] == :yes
      assert responses[slot_b.id] == :if_need_be
    end

    test "rejects an unknown slot id and writes nothing", ctx do
      %{poll: poll, participant: participant} = ctx

      assert {:error, :invalid_slot} =
               Voting.cast_votes(poll, participant.token, %{UUID.generate() => "yes"})

      assert PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).votes ==
               []

      assert PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).voted_at ==
               nil
    end

    test "rejects an invalid response", ctx do
      %{poll: poll, slot_a: slot_a, participant: participant} = ctx

      assert {:error, :invalid_response} =
               Voting.cast_votes(poll, participant.token, %{slot_a.id => "maybe"})

      assert PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).votes ==
               []

      assert PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).voted_at ==
               nil
    end

    test "rejects the whole request when one slot in a multi-slot call is invalid", ctx do
      %{poll: poll, slot_a: slot_a, slot_b: slot_b, participant: participant} = ctx

      assert {:error, :invalid_response} =
               Voting.cast_votes(poll, participant.token, %{
                 slot_a.id => "yes",
                 slot_b.id => "maybe"
               })

      assert PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).votes ==
               []

      assert PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).voted_at ==
               nil
    end

    test "rejects an unknown participant token", ctx do
      %{poll: poll} = ctx

      assert {:error, :unknown_participant} =
               Voting.cast_votes(poll, "no-such-token", %{})
    end

    test "rejects a token that belongs to a different poll", ctx do
      %{poll: poll, slot_a: slot_a} = ctx
      other_participant = insert(:poll_participant)

      assert {:error, :unknown_participant} =
               Voting.cast_votes(poll, other_participant.token, %{slot_a.id => "yes"})
    end

    test "the first responses an unconfirmed participant saves confirm them and send one receipt",
         ctx do
      %{poll: poll, slot_a: slot_a} = ctx
      pending = insert(:poll_participant, poll: poll, confirmed_at: nil, link_sent_at: now())

      assert {:ok, confirmed} = Voting.cast_votes(poll, pending.token, %{slot_a.id => "yes"})
      assert %DateTime{} = confirmed.confirmed_at

      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
      assert pending.id in Enum.map(loaded.participants, & &1.id)
      assert Polls.tallies(loaded)[slot_a.id].yes == 1

      assert {:ok, again} = Voting.cast_votes(poll, pending.token, %{slot_a.id => "no"})
      assert again.confirmed_at == confirmed.confirmed_at

      assert [%{args: %{"participant_id" => id}}] = receipt_jobs()
      assert id == pending.id
    end

    test "a participant's first responses send a receipt, later changes do not", ctx do
      %{poll: poll, slot_a: slot_a, participant: participant} = ctx

      assert {:ok, _first} = Voting.cast_votes(poll, participant.token, %{slot_a.id => "yes"})
      assert [_receipt] = receipt_jobs()

      returning =
        insert(:poll_participant, poll: poll, voted_at: DateTime.utc_now(:second))

      assert {:ok, _again} = Voting.cast_votes(poll, returning.token, %{slot_a.id => "no"})
      assert [_still_one] = receipt_jobs()
    end

    test "someone invited without a name gives it with their first responses", ctx do
      %{poll: poll, slot_a: slot_a} = ctx
      invitee = insert(:poll_participant, poll: poll, name: nil, email: "ada@example.com")

      assert {:error, %Ecto.Changeset{}} =
               Voting.cast_votes(poll, invitee.token, %{slot_a.id => "yes"})

      assert {:error, %Ecto.Changeset{}} =
               Voting.cast_votes(poll, invitee.token, %{slot_a.id => "yes"}, name: "  ")

      unsaved = PollParticipantQueries.get_by_poll_and_token(poll.id, invitee.token)
      assert unsaved.votes == [] and unsaved.voted_at == nil and unsaved.name == nil

      assert {:ok, voted} =
               Voting.cast_votes(poll, invitee.token, %{slot_a.id => "yes"}, name: " Ada ")

      assert voted.name == "Ada"
      assert %DateTime{} = voted.voted_at
    end

    test "a name sent with the responses leaves an existing name alone", ctx do
      %{poll: poll, slot_a: slot_a, participant: participant} = ctx

      assert {:ok, voted} =
               Voting.cast_votes(poll, participant.token, %{slot_a.id => "yes"}, name: "Mallory")

      assert voted.name == participant.name
    end

    test "an unconfirmed participant whose link expired cannot vote", ctx do
      %{poll: poll, slot_a: slot_a} = ctx

      expired =
        insert(:poll_participant,
          poll: poll,
          confirmed_at: nil,
          link_sent_at: DateTime.add(now(), -49, :hour)
        )

      assert {:error, :unknown_participant} =
               Voting.cast_votes(poll, expired.token, %{slot_a.id => "yes"})
    end

    test "confirming is refused once the poll is full, and nothing is written", ctx do
      %{poll: poll, slot_a: slot_a} = ctx
      insert_list(PollSchema.max_participants() - 1, :poll_participant, poll: poll)
      pending = insert(:poll_participant, poll: poll, confirmed_at: nil, link_sent_at: now())

      assert {:error, :poll_full} = Voting.cast_votes(poll, pending.token, %{slot_a.id => "yes"})

      reloaded = PollParticipantQueries.get_by_poll_and_token(poll.id, pending.token)
      assert reloaded.votes == []
      assert reloaded.confirmed_at == nil
      assert receipt_jobs() == []
    end

    test "returns {:error, :voting_closed} on a past-deadline poll", ctx do
      %{slot_a: slot_a, participant: participant} = ctx
      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      closed_poll = insert(:poll, deadline_at: past)
      closed_poll = %{closed_poll | time_slots: [slot_a]}

      assert {:error, :voting_closed} =
               Voting.cast_votes(closed_poll, participant.token, %{slot_a.id => "yes"})
    end

    test "an empty votes map returns the participant without stamping voted_at", ctx do
      %{poll: poll, participant: participant} = ctx

      assert {:ok, returned} = Voting.cast_votes(poll, participant.token, %{})
      assert returned.id == participant.id

      assert PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).voted_at ==
               nil

      assert PollParticipantQueries.get_by_poll_and_token(participant.poll_id, participant.token).votes ==
               []
    end
  end

  defp now, do: DateTime.utc_now(:second)

  defp receipt_jobs do
    Enum.filter(
      all_enqueued(worker: EmailWorker),
      &(&1.args["action"] == "send_poll_vote_receipt")
    )
  end

  defp link_jobs do
    Enum.filter(
      all_enqueued(worker: EmailWorker),
      &(&1.args["action"] == "send_poll_participant_link")
    )
  end
end
