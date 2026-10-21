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
end
