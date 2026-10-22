defmodule Tymeslot.Polls.InvitationsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :unit
  @moduletag :polls

  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Polls.{Invitations, PollParticipantQueries, PollSchema, Voting}
  alias Tymeslot.Workers.EmailWorker

  describe "parse/1" do
    test "reads addresses separated by newlines, commas and semicolons" do
      assert {:ok, entries} =
               Invitations.parse("ada@example.com\ngrace@example.com, alan@example.com; ")

      assert Enum.map(entries, & &1.email) ==
               ["ada@example.com", "grace@example.com", "alan@example.com"]

      assert Enum.all?(entries, &is_nil(&1.name))
    end

    test "names every name a participant could not be given" do
      assert {:error, {:invalid_names, ["A", "Bob%"]}} =
               Invitations.parse(
                 "A <a@example.com>\nBob% <bob@example.com>\nGrace <grace@example.com>"
               )
    end

    test "reports addresses before names" do
      assert {:error, {:invalid_addresses, ["nope"]}} =
               Invitations.parse("A <a@example.com>\nnope")
    end

    test "reads a name given as Name <address>, quoted or not" do
      assert {:ok, [grace, ada]} =
               Invitations.parse("Grace Hopper <Grace@Example.com>\n\"Ada\" <ada@example.com>")

      assert grace == %{name: "Grace Hopper", email: "grace@example.com"}
      assert ada == %{name: "Ada", email: "ada@example.com"}
    end

    test "drops an address given twice, whatever its case" do
      assert {:ok, [%{email: "ada@example.com"}]} =
               Invitations.parse("ada@example.com\nADA@example.com")
    end

    test "names every entry that is not an address" do
      assert {:error, {:invalid_addresses, ["not-an-address", "Bob <bob@>"]}} =
               Invitations.parse("ada@example.com\nnot-an-address\nBob <bob@>")
    end

    test "an empty or missing list is no invitees" do
      assert {:ok, []} = Invitations.parse("  \n , ")
      assert {:ok, []} = Invitations.parse(nil)
    end

    test "refuses more people than a poll can hold" do
      text = Enum.map_join(1..(PollSchema.max_participants() + 1), "\n", &"p#{&1}@example.com")
      assert {:error, :too_many_invitees} = Invitations.parse(text)
    end
  end

  describe "invite/2" do
    setup do
      user = insert(:user, locale: "de")
      poll = insert(:poll, user: user, timezone: "Europe/Berlin")
      %{poll: poll}
    end

    test "adds each invitee as a confirmed participant and emails them", %{poll: poll} do
      {:ok, entries} = Invitations.parse("Grace <grace@example.com>\nada@example.com")

      assert {:ok, %{invited: invited, skipped: []}} =
               Polls.invite_participants(poll.id, poll.user_id, entries)

      assert length(invited) == 2

      grace = PollParticipantQueries.get_by_poll_and_email(poll.id, "grace@example.com")
      ada = PollParticipantQueries.get_by_poll_and_email(poll.id, "ada@example.com")

      assert grace.name == "Grace"
      assert ada.name == nil
      assert %DateTime{} = ada.confirmed_at
      assert %DateTime{} = ada.invited_at
      assert ada.voted_at == nil
      # Written to in the host's language, with times in the poll's zone.
      assert ada.locale == "de"
      assert ada.timezone == "Europe/Berlin"

      for participant <- [grace, ada] do
        assert_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_poll_invitation", "participant_id" => participant.id}
        )
      end

      # They count at once, as people who still owe a vote.
      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
      assert length(loaded.participants) == 2
      assert length(PollParticipantQueries.list_unvoted_for_poll(poll.id)) == 2
    end

    test "skips someone already confirmed on the poll", %{poll: poll} do
      insert(:poll_participant, poll: poll, email: "ada@example.com")

      assert {:ok, %{invited: [], skipped: ["ada@example.com"]}} =
               Polls.invite_participants(poll.id, poll.user_id, [
                 %{email: "ada@example.com", name: nil}
               ])

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "confirms and invites someone who asked for a link but never voted", %{poll: poll} do
      {:ok, :sent} = Voting.request_link(poll, %{name: "Ada", email: "ada@example.com"})

      assert {:ok, %{invited: [ada], skipped: []}} =
               Polls.invite_participants(poll.id, poll.user_id, [
                 %{email: "ada@example.com", name: nil}
               ])

      assert %DateTime{} = ada.confirmed_at
      assert %DateTime{} = ada.invited_at
      assert ada.name == "Ada"

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_invitation", "participant_id" => ada.id}
      )
    end

    test "the host's name for someone wins over the one they gave when asking", %{poll: poll} do
      {:ok, :sent} = Voting.request_link(poll, %{name: "Mallory", email: "ada@example.com"})

      assert {:ok, %{invited: [ada], skipped: []}} =
               Polls.invite_participants(poll.id, poll.user_id, [
                 %{email: "ada@example.com", name: "Ada Lovelace"}
               ])

      assert ada.name == "Ada Lovelace"

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "ada@example.com").name ==
               "Ada Lovelace"

      assert {:ok, _outcome} =
               Voting.request_link(poll, %{name: "Mallory", email: "ada@example.com"})

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "ada@example.com").name ==
               "Ada Lovelace"
    end

    test "a host's name the rules refuse invites nobody and changes nothing", %{poll: poll} do
      {:ok, :sent} = Voting.request_link(poll, %{name: "Ada", email: "ada@example.com"})

      assert {:error, %Ecto.Changeset{}} =
               Polls.invite_participants(poll.id, poll.user_id, [
                 %{email: "ada@example.com", name: "Ada%"}
               ])

      unchanged = PollParticipantQueries.get_by_poll_and_email(poll.id, "ada@example.com")
      assert unchanged.name == "Ada"
      assert unchanged.confirmed_at == nil
    end

    test "invites nobody when the invitees would overfill the poll", %{poll: poll} do
      insert_list(PollSchema.max_participants() - 1, :poll_participant, poll: poll)
      {:ok, entries} = Invitations.parse("ada@example.com, grace@example.com")

      assert {:error, :poll_full} = Polls.invite_participants(poll.id, poll.user_id, entries)
      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "ada@example.com") == nil
      assert all_enqueued(worker: EmailWorker) == []
    end

    test "refuses a poll that is no longer open" do
      poll = insert(:poll, status: :cancelled)

      assert {:error, :not_open} =
               Polls.invite_participants(poll.id, poll.user_id, [
                 %{email: "ada@example.com", name: nil}
               ])
    end
  end

  describe "Polls.create_poll/2 with invitees" do
    setup do
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      attrs = %{
        title: "Team sync",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [%{start_time: start_time}]
      }

      %{user: insert(:user), attrs: attrs}
    end

    test "invites them with the poll and emails them once it is saved", %{
      user: user,
      attrs: attrs
    } do
      {:ok, invitees} = Invitations.parse("ada@example.com")

      assert {:ok, poll} = Polls.create_poll(user.id, Map.put(attrs, :invitees, invitees))
      assert [%{email: "ada@example.com"} = ada] = poll.participants

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_invitation", "participant_id" => ada.id}
      )
    end

    test "a poll that fails to save invites nobody", %{user: user, attrs: attrs} do
      {:ok, invitees} = Invitations.parse("ada@example.com")
      past = DateTime.add(DateTime.utc_now(), -1, :day)

      assert {:error, :slot_in_past} =
               Polls.create_poll(
                 user.id,
                 Map.put(%{attrs | slots: [%{start_time: past}]}, :invitees, invitees)
               )

      assert all_enqueued(worker: EmailWorker) == []
    end
  end
end
