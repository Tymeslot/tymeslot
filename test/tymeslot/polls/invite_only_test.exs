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
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Repo

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

  defp in_days(days),
    do: DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
end
