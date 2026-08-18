defmodule Tymeslot.Polls.UpdateDetailsTest do
  @moduledoc """
  Covers `Polls.update_details/3`: the host correcting a poll's wording after
  guests already hold the voting link.
  """
  use Tymeslot.DataCase, async: false

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Repo

  @moduletag :integration

  setup do
    user = insert(:user)
    poll = insert(:poll, user: user, status: :open, title: "Tema sync", meeting_type_id: nil)
    insert(:poll_time_slot, poll: poll)

    %{user: user, poll: poll}
  end

  describe "update_details/3" do
    test "rewrites the title and description", %{user: user, poll: poll} do
      assert {:ok, updated} =
               Polls.update_details(poll.id, user.id, %{
                 "title" => "Team sync",
                 "description" => "Bring last week's notes."
               })

      assert updated.title == "Team sync"
      assert updated.description == "Bring last week's notes."

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.title == "Team sync"
      assert reloaded.description == "Bring last week's notes."
    end

    test "notifies subscribers so an open voting page shows the correction", %{
      user: user,
      poll: poll
    } do
      :ok = Polls.subscribe(poll.id)

      assert {:ok, _updated} = Polls.update_details(poll.id, user.id, %{"title" => "Team sync"})

      assert_receive {:poll_updated, poll_id}
      assert poll_id == poll.id
    end

    test "trims the title and stores a blank description as nil", %{user: user, poll: poll} do
      assert {:ok, updated} =
               Polls.update_details(poll.id, user.id, %{
                 "title" => "  Team sync  ",
                 "description" => "   "
               })

      assert updated.title == "Team sync"
      assert updated.description == nil
    end

    test "rejects a blank title", %{user: user, poll: poll} do
      assert {:error, changeset} = Polls.update_details(poll.id, user.id, %{"title" => "   "})
      assert %{title: ["can't be blank"]} = errors_on(changeset)

      # The stored poll is untouched.
      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.title == "Tema sync"
    end

    test "rejects a title past the column limit", %{user: user, poll: poll} do
      assert {:error, changeset} =
               Polls.update_details(poll.id, user.id, %{"title" => String.duplicate("a", 256)})

      assert %{title: [_message]} = errors_on(changeset)
    end

    test "leaves the candidate times, duration and timezone alone", %{user: user, poll: poll} do
      {:ok, before} = Polls.get_poll_for_host(poll.id, user.id)

      # These are the terms guests voted against, so the changeset must not cast
      # them even when a caller passes them.
      assert {:ok, updated} =
               Polls.update_details(poll.id, user.id, %{
                 "title" => "Team sync",
                 "duration_minutes" => 999,
                 "timezone" => "Pacific/Auckland",
                 "status" => "cancelled"
               })

      assert updated.duration_minutes == before.duration_minutes
      assert updated.timezone == before.timezone
      assert updated.status == :open
    end

    test "refuses a confirmed poll", %{user: user, poll: poll} do
      poll |> Changeset.change(status: :confirmed) |> Repo.update!()

      assert {:error, :not_open} =
               Polls.update_details(poll.id, user.id, %{"title" => "Team sync"})
    end

    test "refuses a cancelled poll", %{user: user, poll: poll} do
      {:ok, _cancelled} = Polls.cancel_poll(poll.id, user.id)

      assert {:error, :not_open} =
               Polls.update_details(poll.id, user.id, %{"title" => "Team sync"})
    end

    test "refuses a poll belonging to someone else", %{poll: poll} do
      other = insert(:user)

      assert {:error, :not_found} =
               Polls.update_details(poll.id, other.id, %{"title" => "Team sync"})
    end
  end
end
