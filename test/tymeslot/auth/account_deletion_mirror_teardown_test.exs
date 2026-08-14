defmodule Tymeslot.Auth.AccountDeletionMirrorTeardownTest do
  @moduledoc """
  Deleting an account withdraws the mirror placeholders its sync links wrote
  before the rows naming them are destroyed.

  This is the last moment those placeholders can be removed at all. Once the
  user row goes, the calendar integrations, the sync links and the mapping rows
  go with it, and every busy block the links wrote onto the organiser's
  calendars is left behind with nothing that could ever identify it as ours —
  and, being deliberately indistinguishable from an ordinary "Busy" block, with
  nothing that could tell the organiser what it is either. So a teardown that
  cannot finish aborts the deletion, exactly as a failing external hook does.

  The hook itself is re-asserted here on purpose. Teardown occupies the same
  stretch of `delete_account/1` and must not have displaced the single
  `:account_deletion_hook` slot, which is reserved for an external layer (the
  SaaS billing overlay) tearing down state that keeps costing the user money.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  defmodule RecordingHook do
    @moduledoc false
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(user_id) do
      send(:account_deletion_mirror_teardown_test, {:hook_ran, user_id})
      :ok
    end
  end

  defmodule FailingHook do
    @moduledoc false
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: {:error, :subscription_cancel_failed}
  end

  setup do
    original = Application.get_env(:tymeslot, :account_deletion_hook)
    Application.put_env(:tymeslot, :account_deletion_hook, nil)
    on_exit(fn -> Application.put_env(:tymeslot, :account_deletion_hook, original) end)

    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "google")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    %{user: user, source: source, target: target, link: link}
  end

  test "withdraws every placeholder before the user's rows go", %{
    user: user,
    target: target,
    link: link
  } do
    first = mirror_for_link(link, source_uid: "src-1", target_uid: "uid-a")
    second = mirror_for_link(link, source_uid: "src-2", target_uid: "uid-b")
    test_pid = self()

    expect(Tymeslot.CalendarMock, :delete_event, 2, fn uid, {integration_id, user_id}, _opts ->
      # The user must still exist while the provider is being asked: the call
      # is made in their name, against credentials their row still owns.
      assert Repo.get(UserSchema, user_id)
      send(test_pid, {:withdrawn, uid, integration_id})
      :ok
    end)

    assert {:ok, _deleted} = Auth.delete_account(user)

    assert_received {:withdrawn, uid_a, integration_id}
    assert_received {:withdrawn, uid_b, _second_integration}
    assert integration_id == target.id
    assert Enum.sort([uid_a, uid_b]) == ["uid-a", "uid-b"]

    refute Repo.get(UserSchema, user.id)
    refute Repo.get(CalendarSyncMirrorSchema, first.id)
    refute Repo.get(CalendarSyncMirrorSchema, second.id)
  end

  test "aborts the deletion and leaves the user intact when a placeholder survives", %{
    user: user,
    link: link
  } do
    mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "uid-a")

    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
      {:error, :service_unavailable}
    end)

    assert {:error, :service_unavailable} = Auth.delete_account(user)

    assert Repo.get(UserSchema, user.id),
           "the user must survive while a placeholder they cannot reach is still on a calendar"

    assert %{state: "pending_delete"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
  end

  test "deletes an account whose links never mirrored anything", %{user: user} do
    assert {:ok, _deleted} = Auth.delete_account(user)
    refute Repo.get(UserSchema, user.id)
  end

  test "still runs the configured external hook", %{user: user, link: link} do
    Process.register(self(), :account_deletion_mirror_teardown_test)
    Application.put_env(:tymeslot, :account_deletion_hook, RecordingHook)

    mirror_for_link(link, source_uid: "src-1", target_uid: "uid-a")
    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

    assert {:ok, _deleted} = Auth.delete_account(user)

    assert_received {:hook_ran, hook_user_id}
    assert hook_user_id == user.id
  end

  test "a failing external hook still aborts before any placeholder is touched", %{
    user: user,
    link: link
  } do
    Application.put_env(:tymeslot, :account_deletion_hook, FailingHook)
    mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "uid-a")

    # No `expect` for delete_event: the hook fails first, so reaching the
    # provider at all would be a Mox failure.
    assert {:error, :subscription_cancel_failed} = Auth.delete_account(user)

    assert Repo.get(UserSchema, user.id)
    assert %{state: "active"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
  end
end
