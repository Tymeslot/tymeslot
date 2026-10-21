defmodule Tymeslot.Polls.InviteOnlyTest do
  @moduledoc """
  Covers invite-only polls in the domain: the stored flag and its default,
  refusing link requests, refusing to confirm a request left over from before
  the switch, and switching a poll either way.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :unit
  @moduletag :polls

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantQueries, PollParticipantSchema, PollSchema, Voting}
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  describe "the stored flag" do
    test "a poll is open to link requests unless made invite-only" do
      poll = insert(:poll)

      assert Repo.get!(PollSchema, poll.id).invite_only == false
    end

    test "the creation and editing changesets both take it" do
      creation = PollSchema.creation_changeset(%PollSchema{}, %{invite_only: true})
      details = PollSchema.details_changeset(insert(:poll), %{"invite_only" => "true"})

      assert Changeset.get_change(creation, :invite_only) == true
      assert Changeset.get_change(details, :invite_only) == true
    end
  end

  describe "create_poll/2" do
    setup do
      %{user: insert(:user)}
    end

    test "is invite-only when people are invited with it and the host did not say", %{user: user} do
      {:ok, poll} =
        Polls.create_poll(
          user.id,
          poll_attrs(invitees: [%{email: "grace@example.com", name: "Grace"}])
        )

      assert poll.invite_only
    end

    test "is open to anyone with the link when nobody is invited with it", %{user: user} do
      {:ok, poll} = Polls.create_poll(user.id, poll_attrs([]))

      refute poll.invite_only
    end

    test "keeps the host's choice whatever the invitees", %{user: user} do
      {:ok, open} =
        Polls.create_poll(
          user.id,
          poll_attrs(invite_only: false, invitees: [%{email: "grace@example.com", name: nil}])
        )

      {:ok, closed} = Polls.create_poll(user.id, poll_attrs(invite_only: true))

      refute open.invite_only
      assert closed.invite_only
    end
  end

  describe "request_link/2 on an invite-only poll" do
    test "refuses a new address, writing nothing and sending nothing" do
      poll = insert(:poll, invite_only: true)

      assert {:error, :invite_only} =
               Voting.request_link(poll, %{name: "Mallory", email: "mallory@example.com"})

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "mallory@example.com") == nil
      refute_enqueued(worker: EmailWorker)
    end

    test "refuses an invited address too, without sending its link again" do
      poll = insert(:poll, invite_only: true)
      sent_at = DateTime.add(now(), -1, :hour)

      invitee =
        insert(:poll_participant,
          poll: poll,
          email: "grace@example.com",
          confirmed_at: now(),
          invited_at: now(),
          link_sent_at: sent_at
        )

      assert {:error, :invite_only} =
               Voting.request_link(poll, %{name: "Grace", email: "grace@example.com"})

      assert Repo.get!(PollParticipantSchema, invitee.id).link_sent_at == sent_at
      refute_enqueued(worker: EmailWorker)
    end

    test "is checked before anything else, even on a poll that has closed" do
      poll = insert(:poll, invite_only: true, status: :cancelled)

      assert {:error, :invite_only} =
               Voting.request_link(poll, %{name: "Mallory", email: "mallory@example.com"})
    end

    test "holds for a page loaded before the host switched the poll" do
      stale = insert(:poll, invite_only: false)
      {:ok, _poll} = Polls.update_details(stale.id, stale.user_id, %{"invite_only" => true})

      assert {:error, :invite_only} =
               Voting.request_link(stale, %{name: "Mallory", email: "mallory@example.com"})

      assert PollParticipantQueries.count_unconfirmed(stale.id) == 0
    end
  end

  describe "cast_votes/4 on an invite-only poll" do
    setup do
      poll = insert(:poll, invite_only: true)
      slot = insert(:poll_time_slot, poll: poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)
      %{poll: poll, slot: slot}
    end

    test "an invited participant votes through their link", %{poll: poll, slot: slot} do
      invitee = insert(:poll_participant, poll: poll, confirmed_at: now(), invited_at: now())

      assert {:ok, voted} = Voting.cast_votes(poll, invitee.token, %{slot.id => "yes"})
      assert %DateTime{} = voted.voted_at
    end

    test "someone confirmed before the switch keeps voting", %{poll: poll, slot: slot} do
      earlier = insert(:poll_participant, poll: poll, confirmed_at: now(), voted_at: now())

      assert {:ok, _voted} = Voting.cast_votes(poll, earlier.token, %{slot.id => "no"})
    end

    test "a link request left from before the switch cannot confirm", %{poll: poll, slot: slot} do
      pending =
        insert(:poll_participant, poll: poll, confirmed_at: nil, link_sent_at: now())

      assert {:error, :invite_only} = Voting.cast_votes(poll, pending.token, %{slot.id => "yes"})

      reloaded = Repo.get!(PollParticipantSchema, pending.id)
      assert reloaded.confirmed_at == nil
      assert reloaded.voted_at == nil
      assert Polls.tallies(elem(Polls.get_poll_for_voting(poll.token), 1))[slot.id].yes == 0
    end
  end

  defp poll_attrs(extra) do
    Map.merge(
      %{
        title: "Offsite",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [%{start_time: in_days(7)}]
      },
      Map.new(extra)
    )
  end

  defp now, do: DateTime.utc_now(:second)

  defp in_days(days),
    do: DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
end
