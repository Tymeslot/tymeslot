defmodule Tymeslot.Auth.AccountDeletion.RunnerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Ecto.Query
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Auth.AccountDeletion
  alias Tymeslot.Auth.AccountDeletion.Runner
  alias Tymeslot.Auth.{UserQueries, UserSchema}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.{AccountDeletionWorker, EmailWorker, WebhookWorker}

  defmodule RefusingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, _feedback), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: {:error, :billing_unreachable}
  end

  # Stands in for a concurrent request landing between the runner's read and
  # the deletion's row lock, as the hook runs exactly in that gap.
  defmodule RacingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, _feedback), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(user_id) do
      case Application.fetch_env!(:tymeslot, :racing_hook_action) do
        :delete_row ->
          Repo.delete!(%UserSchema{id: user_id})

        {:reschedule, at} ->
          Repo.update_all(
            from(u in UserSchema, where: u.id == ^user_id),
            set: [deletion_scheduled_at: at]
          )
      end

      :ok
    end
  end

  setup do
    with_config(:tymeslot, :account_deletion_hook, nil)
    :ok
  end

  defp pending_user(scheduled_at) do
    insert(:user,
      deletion_requested_at: DateTime.add(scheduled_at, -14, :day),
      deletion_scheduled_at: DateTime.truncate(scheduled_at, :second)
    )
  end

  defp past, do: DateTime.add(DateTime.utc_now(:second), -60, :second)
  defp future, do: DateTime.add(DateTime.utc_now(:second), 3, :day)

  describe "run/1" do
    test "deletes a due account, its meetings and the jobs queued for them, telling no guest" do
      user = pending_user(past())
      meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)

      %{
        "action" => "send_reminder_emails",
        "meeting_id" => meeting.id,
        "reminder_value" => 1,
        "reminder_unit" => "hours"
      }
      |> EmailWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day))
      |> Oban.insert!()

      assert Runner.run(user.id) == {:ok, :deleted}

      refute Repo.get(UserSchema, user.id)
      refute Repo.get(MeetingSchema, meeting.id)
      assert all_enqueued(worker: EmailWorker) == []
      refute_enqueued(worker: WebhookWorker)
    end

    test "leaves a restored account alone" do
      user = insert(:user)

      assert Runner.run(user.id) == {:ok, :not_pending}
      assert Repo.get(UserSchema, user.id)
    end

    test "snoozes when it runs before the account is due" do
      user = pending_user(future())

      assert {:snooze, seconds} = Runner.run(user.id)
      assert seconds > 2 * 86_400
      assert Repo.get(UserSchema, user.id)
    end

    test "is done when the account is already gone" do
      assert Runner.run(-1) == {:ok, :already_deleted}
    end

    test "is done when the account is deleted between the read and the lock" do
      with_config(:tymeslot, :account_deletion_hook, RacingHook)
      with_config(:tymeslot, :racing_hook_action, :delete_row)
      user = pending_user(past())

      assert Runner.run(user.id) == {:ok, :already_deleted}
    end

    test "leaves an account restored and re-requested before the lock, and its jobs" do
      with_config(:tymeslot, :account_deletion_hook, RacingHook)
      new_date = DateTime.add(DateTime.utc_now(:second), 14, :day)
      with_config(:tymeslot, :racing_hook_action, {:reschedule, new_date})
      user = pending_user(past())
      meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)

      job =
        %{
          "action" => "send_reminder_emails",
          "meeting_id" => meeting.id,
          "reminder_value" => 1,
          "reminder_unit" => "hours"
        }
        |> EmailWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day))
        |> Oban.insert!()

      assert Runner.run(user.id) == {:ok, :not_pending}
      assert Repo.get(UserSchema, user.id)
      assert Repo.get(MeetingSchema, meeting.id)
      assert Repo.get(Oban.Job, job.id)
    end

    test "returns the hook's refusal so the job retries, and keeps the account" do
      with_config(:tymeslot, :account_deletion_hook, RefusingHook)
      user = pending_user(past())

      assert Runner.run(user.id) == {:error, :billing_unreachable}
      assert Repo.get(UserSchema, user.id)
    end
  end

  describe "AccountDeletion.delete_account/2 with only_if_pending" do
    test "refuses an account that is no longer pending" do
      user = insert(:user)

      assert AccountDeletion.delete_account(user, only_if_pending: true) == {:error, :not_pending}
      assert Repo.get(UserSchema, user.id)
    end
  end

  describe "AccountDeletion.delete_account/2 with a future deletion date" do
    test "does not delete an account whose grace period is not over" do
      stale = pending_user(past())

      Repo.update_all(from(u in UserSchema, where: u.id == ^stale.id),
        set: [deletion_scheduled_at: DateTime.add(DateTime.utc_now(:second), 14, :day)]
      )

      assert AccountDeletion.delete_account(stale, only_if_pending: true) ==
               {:error, :not_pending}

      assert Repo.get(UserSchema, stale.id)
    end

    test "reports an account that is already gone as not found" do
      user = pending_user(past())
      Repo.delete!(user)

      assert AccountDeletion.delete_account(user, only_if_pending: true) == {:error, :not_found}
    end
  end

  describe "enqueue_overdue/1" do
    test "queues one job per overdue account, and none twice" do
      overdue = pending_user(past())
      _not_yet = pending_user(future())
      _active = insert(:user)

      assert Auth.enqueue_overdue_account_deletions() == 1
      assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => overdue.id})
      assert Auth.enqueue_overdue_account_deletions() == 0
    end
  end

  describe "the last admin who can sign in" do
    setup :capture_admin_alerts

    setup do
      # The other admin left during the grace period.
      admin = pending_user_from(insert(:user, is_admin: true))
      %{admin: admin}
    end

    test "is held rather than deleted, stays restorable, and operators are told", %{
      admin: admin
    } do
      assert {:snooze, seconds} = Runner.run(admin.id)
      assert_in_delta seconds, 86_400, 5

      held = Repo.get!(UserSchema, admin.id)
      assert DateTime.compare(held.deletion_scheduled_at, DateTime.utc_now()) == :gt
      assert held.deletion_requested_at == admin.deletion_requested_at

      assert_received {:send_alert, :account_deletion_held_last_admin, payload}
      assert payload.user_id == admin.id
      refute_received {:send_alert, :account_deletion_stalled, _payload}

      assert {:ok, restored} = Auth.restore_account(held)
      refute restored.deletion_scheduled_at
    end

    test "is deleted once another admin who can sign in is back", %{admin: admin} do
      insert(:user, is_admin: true)

      assert Runner.run(admin.id) == {:ok, :deleted}
      refute_received {:send_alert, _type, _payload}
      refute Repo.get(UserSchema, admin.id)
    end

    test "is held, then deleted on the next run once another admin can sign in", %{
      admin: admin
    } do
      assert {:snooze, _seconds} = Runner.run(admin.id)
      assert Repo.get(UserSchema, admin.id)

      insert(:user, is_admin: true)
      # The day's hold has passed.
      pending_user_from(Repo.get!(UserSchema, admin.id))

      assert Runner.run(admin.id) == {:ok, :deleted}
      refute Repo.get(UserSchema, admin.id)
    end

    test "is neither held nor deleted when the hold cannot be written", %{admin: admin} do
      # Patched with :meck: the hold's write has no validation or constraint
      # to fail, and the row is locked, so no real input makes it refuse.
      # Unloaded when the test process exits.
      :meck.new(UserQueries, [:passthrough])

      :meck.expect(UserQueries, :mark_deletion_scheduled, fn user, _requested_at, _until ->
        {:error, Changeset.add_error(Changeset.change(user), :deletion_scheduled_at, "invalid")}
      end)

      assert {:error, %Changeset{}} = Runner.run(admin.id)

      # Rolled back: still there, still due at its old date, and no alert.
      kept = Repo.get!(UserSchema, admin.id)
      assert kept.deletion_scheduled_at == admin.deletion_scheduled_at
      refute_received {:send_alert, _type, _payload}
    end

    test "is deleted when the release shell forces it", %{admin: admin} do
      assert Runner.run(admin.id, force: true) == {:ok, :deleted}
      refute Repo.get(UserSchema, admin.id)
    end
  end

  defp pending_user_from(user) do
    user
    |> Changeset.change(
      deletion_requested_at: DateTime.add(past(), -14, :day),
      deletion_scheduled_at: past()
    )
    |> Repo.update!()
  end
end
