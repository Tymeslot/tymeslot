defmodule Tymeslot.Auth.UserQueriesDeletionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth
  @moduletag :queries

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AccountDeletionWorker

  defp now, do: DateTime.utc_now(:second)

  describe "mark_deletion_scheduled/3 and clear_deletion_schedule/1" do
    test "stamps both timestamps, then clears them" do
      user = insert(:user)
      requested_at = now()
      scheduled_at = DateTime.add(requested_at, 14, :day)

      assert {:ok, marked} = UserQueries.mark_deletion_scheduled(user, requested_at, scheduled_at)
      assert marked.deletion_requested_at == requested_at
      assert marked.deletion_scheduled_at == scheduled_at

      assert {:ok, cleared} = UserQueries.clear_deletion_schedule(marked)
      assert cleared.deletion_requested_at == nil
      assert cleared.deletion_scheduled_at == nil
    end
  end

  describe "deletion_pending?/1" do
    test "is true only for an account with a deletion scheduled" do
      pending = insert(:user, deletion_requested_at: now(), deletion_scheduled_at: now())
      active = insert(:user)

      assert UserQueries.deletion_pending?(pending.id)
      refute UserQueries.deletion_pending?(active.id)
      refute UserQueries.deletion_pending?(-1)
    end
  end

  describe "Auth.deletion_pending?/1" do
    test "answers for a struct from its fields and for an id from the database" do
      pending = insert(:user, deletion_requested_at: now(), deletion_scheduled_at: now())
      active = insert(:user)

      assert Auth.deletion_pending?(pending)
      refute Auth.deletion_pending?(active)
      assert Auth.deletion_pending?(pending.id)
      refute Auth.deletion_pending?(active.id)

      # A struct is answered from its own fields, never the database.
      assert Auth.deletion_pending?(%UserSchema{id: -1, deletion_scheduled_at: now()})
    end
  end

  describe "list_due_deletion_ids/3" do
    test "lists overdue accounts oldest first, up to the limit" do
      t = now()

      older =
        insert(:user, deletion_requested_at: t, deletion_scheduled_at: DateTime.add(t, -2, :day))

      due_now = insert(:user, deletion_requested_at: t, deletion_scheduled_at: t)

      _future =
        insert(:user, deletion_requested_at: t, deletion_scheduled_at: DateTime.add(t, 1, :day))

      _active = insert(:user)

      assert UserQueries.list_due_deletion_ids(t, 10) == [older.id, due_now.id]
      assert UserQueries.list_due_deletion_ids(t, 1) == [older.id]
    end

    test "with a worker, leaves out accounts that have an incomplete job of it" do
      t = now()
      incomplete = ~w(available scheduled executing retryable suspended)
      finished = ~w(completed discarded cancelled)

      due = fn ->
        insert(:user, deletion_requested_at: t, deletion_scheduled_at: DateTime.add(t, -1, :day))
      end

      queued =
        for state <- incomplete, into: %{} do
          user = due.()
          insert_job(user.id, state)
          {state, user.id}
        end

      done =
        for state <- finished, into: %{} do
          user = due.()
          insert_job(user.id, state)
          {state, user.id}
        end

      unqueued = due.()

      assert map_size(queued) == 5
      assert map_size(done) == 3

      listed = UserQueries.list_due_deletion_ids(t, 100, AccountDeletionWorker)

      assert Enum.sort(listed) == Enum.sort([unqueued.id | Map.values(done)])
      assert Enum.filter(listed, &(&1 in Map.values(queued))) == []
      # Without the worker nothing is left out.
      assert length(UserQueries.list_due_deletion_ids(t, 100)) == 9
    end

    test "a job for another account does not hide this one" do
      t = now()
      due = insert(:user, deletion_requested_at: t, deletion_scheduled_at: t)
      other = insert(:user)
      insert_job(other.id, "available")

      assert UserQueries.list_due_deletion_ids(t, 10, AccountDeletionWorker) == [due.id]
    end
  end

  describe "existing_ids/1" do
    test "returns only the ids that still have a row" do
      user = insert(:user)

      assert UserQueries.existing_ids([user.id, -5]) == [user.id]
      assert UserQueries.existing_ids([]) == []
    end
  end

  defp insert_job(user_id, state) do
    job = Oban.insert!(AccountDeletionWorker.new(%{user_id: user_id}))

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
  end
end
