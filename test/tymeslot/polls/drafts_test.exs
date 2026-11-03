defmodule Tymeslot.Polls.DraftsTest do
  @moduledoc """
  A poll saved as a draft and published later: nothing leaves the dashboard
  while it is a draft, and publishing does everything creating the poll
  would have done, judged at the moment of publication.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user)
    insert(:profile, user: user, username: "draft-host-#{user.id}")
    insert(:calendar_integration, user: user, provider: "debug")
    future = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
    {:ok, user: user, future: future}
  end

  defp attrs(future, overrides \\ %{}) do
    Map.merge(
      %{
        title: "Team sync",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        deadline_at: DateTime.add(future, -1, :hour),
        slots: [%{start_time: future}, %{start_time: DateTime.add(future, 1, :hour)}],
        invitees: [%{email: "ada@example.com", name: "Ada Lovelace"}]
      },
      overrides
    )
  end

  defp participants(poll),
    do: Repo.all(from p in PollParticipantSchema, where: p.poll_id == ^poll.id)

  describe "create_draft/2" do
    test "saves the poll and its times without inviting or emailing anyone", %{
      user: user,
      future: future
    } do
      assert {:ok, %PollSchema{status: :draft} = draft} =
               Polls.create_draft(user.id, attrs(future))

      assert length(draft.time_slots) == 2
      assert participants(draft) == []

      assert PollSchema.draft_invitees(draft) == [
               %{email: "ada@example.com", name: "Ada Lovelace"}
             ]

      refute_enqueued(worker: EmailWorker)
    end

    test "has no link that resolves, and is not counted among the open polls", %{
      user: user,
      future: future
    } do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))

      assert Polls.get_poll_for_voting(draft.token) == {:error, :not_found}
      assert Polls.count_open_polls(user.id) == 0
      assert [%{id: id}] = Polls.list_polls(user.id)
      assert id == draft.id
    end

    test "needs no times yet, nor a calendar", %{future: future} do
      user = insert(:user)

      assert {:ok, %{status: :draft, time_slots: []}} =
               Polls.create_draft(user.id, attrs(future, %{slots: []}))
    end

    test "refuses a time already past", %{user: user, future: future} do
      past = DateTime.add(DateTime.utc_now(), -1, :hour)

      assert Polls.create_draft(user.id, attrs(future, %{slots: [%{start_time: past}]})) ==
               {:error, :slot_in_past}
    end
  end

  describe "update_draft/3" do
    test "replaces the draft's details, times and invitees", %{user: user, future: future} do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))
      later = DateTime.add(future, 1, :day)

      assert {:ok, updated} =
               Polls.update_draft(
                 draft.id,
                 user.id,
                 attrs(future, %{
                   title: "Planning",
                   slots: [%{start_time: later}],
                   invitees: [%{email: "bob@example.com", name: nil}]
                 })
               )

      assert updated.status == :draft
      assert updated.title == "Planning"
      assert [%{start_time: ^later, position: 0}] = updated.time_slots
      assert PollSchema.draft_invitees(updated) == [%{email: "bob@example.com", name: nil}]
    end

    test "refuses a poll that is no longer a draft", %{user: user, future: future} do
      {:ok, poll} = Polls.create_poll(user.id, attrs(future, %{invitees: []}))

      assert Polls.update_draft(poll.id, user.id, attrs(future)) == {:error, :not_draft}
    end

    test "refuses another host's draft", %{user: user, future: future} do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))

      assert Polls.update_draft(draft.id, insert(:user).id, attrs(future)) ==
               {:error, :not_found}
    end
  end

  describe "publish_draft/3" do
    test "opens the poll, invites its invitees and schedules their emails and the nudge", %{
      user: user,
      future: future
    } do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))

      assert {:ok, %PollSchema{status: :open, draft_invitees: nil} = poll} =
               Polls.publish_draft(draft.id, user.id, attrs(future))

      assert [%{email: "ada@example.com", name: "Ada Lovelace"} = ada] = participants(poll)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_invitation", "participant_id" => ada.id}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_host_nudge", "poll_id" => poll.id}
      )

      assert {:ok, %{id: id}} = Polls.get_poll_for_voting(draft.token)
      assert id == poll.id
      assert Polls.count_open_polls(user.id) == 1
    end

    test "publishes what the form holds at publication", %{user: user, future: future} do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))

      assert {:ok, poll} =
               Polls.publish_draft(draft.id, user.id, attrs(future, %{title: "Final title"}))

      assert poll.title == "Final title"
    end

    test "judges the deadline at publication, leaving a draft whose deadline passed as it was",
         %{user: user, future: future} do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))

      # The deadline set while drafting has passed since.
      passed = DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:second)
      Repo.update!(Changeset.change(draft, deadline_at: passed))

      held = attrs(future, %{deadline_at: passed})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Polls.publish_draft(draft.id, user.id, held)

      assert {"must be in the future", _opts} = changeset.errors[:deadline_at]
      assert {:ok, %{status: :draft}} = Polls.get_poll_for_host(draft.id, user.id)
      assert participants(draft) == []
      refute_enqueued(worker: EmailWorker)
    end

    test "refuses a draft with no times", %{user: user, future: future} do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future, %{slots: []}))

      assert Polls.publish_draft(draft.id, user.id, attrs(future, %{slots: []})) ==
               {:error, :no_slots}
    end

    test "needs a calendar connected, as creating a poll does", %{future: future} do
      user = insert(:user)
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))

      assert Polls.publish_draft(draft.id, user.id, attrs(future)) == {:error, :no_calendar}
    end

    test "refuses a poll already published", %{user: user, future: future} do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))
      {:ok, _poll} = Polls.publish_draft(draft.id, user.id, attrs(future))

      assert Polls.publish_draft(draft.id, user.id, attrs(future)) == {:error, :not_draft}
    end
  end

  describe "a draft elsewhere" do
    test "cannot be cancelled or invited to, but can be deleted", %{user: user, future: future} do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))

      assert Polls.cancel_poll(draft.id, user.id) == {:error, :not_open}

      assert Polls.invite_participants(draft.id, user.id, [%{email: "bob@example.com", name: nil}]) ==
               {:error, :not_open}

      assert Polls.delete_poll(draft.id, user.id) == :ok
      assert Polls.get_poll_for_host(draft.id, user.id) == {:error, :not_found}
    end

    test "is not deleted once it has been published", %{user: user, future: future} do
      {:ok, draft} = Polls.create_draft(user.id, attrs(future))
      {:ok, _poll} = Polls.publish_draft(draft.id, user.id, attrs(future))

      assert Polls.delete_poll(draft.id, user.id) == {:error, :still_open}
      assert {:ok, %{status: :open}} = Polls.get_poll_for_host(draft.id, user.id)
    end
  end
end
