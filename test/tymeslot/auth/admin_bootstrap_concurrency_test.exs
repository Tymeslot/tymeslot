defmodule Tymeslot.Auth.AdminBootstrapConcurrencyTest do
  @moduledoc """
  Two first sign-ups racing on a fresh install: exactly one becomes admin.

  The sandbox cannot show this. It gives a test one connection, so two
  "concurrent" transactions queue on it and the second always sees the first
  committed. Each sign-up here therefore runs on its own real connection
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) and commits for real, which is
  why the module is synchronous (ExUnit runs it after every async module, with
  nothing else in flight), why `on_exit` deletes what it committed, and why
  the race test reopens the bootstrap and closes it again itself.

  The race is staged so that neither transaction has committed when both
  reach the promotion check: each inserts its user, then both are released
  together. Without the lock both see themselves as the only user and both
  are promoted. With it, the second waits for the first to commit and then
  finds the install already bootstrapped. The only timing involved is a
  bounded wait for the second check, which under the lock cannot arrive until
  the first transaction is allowed to commit.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.AppSettings.AppSettingsQueries
  alias Tymeslot.Auth.{AdminBootstrap, UserSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Test.AdminBootstrapHelpers

  # How long to wait for a second promotion check before letting the first
  # transaction commit. Under the lock the second check never arrives inside
  # it; without the lock it arrives almost at once.
  @second_check_window 500

  setup do
    emails =
      for n <- 1..2, do: "first-signup-#{n}-#{System.unique_integer([:positive])}@example.com"

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(u in UserSchema, where: u.email in ^emails))
      end)
    end)

    %{emails: emails}
  end

  test "concurrent first sign-ups promote exactly one user", %{emails: emails} do
    # The race needs a fresh install, committed where both connections see it,
    # and closed again afterwards as `test_helper.exs` left it.
    Sandbox.unboxed_run(Repo, fn -> AdminBootstrapHelpers.reopen_admin_bootstrap() end)

    try do
      assert Enum.count(race_first_sign_ups(emails), & &1.is_admin) == 1
    after
      Sandbox.unboxed_run(Repo, &AdminBootstrapHelpers.close!/0)
    end
  end

  defp race_first_sign_ups(emails) do
    parent = self()

    tasks =
      for email <- emails do
        Task.async(fn -> sign_up(parent, email) end)
      end

    for _task <- tasks, do: assert_receive({:inserted, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :check))

    assert_receive {:checked, _first}, 5_000

    receive do
      {:checked, _second} -> :ok
    after
      @second_check_window -> :ok
    end

    Enum.each(tasks, &send(&1.pid, :commit))

    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  # Every sign-up on an established install passes through here, so it must
  # not queue on the global bootstrap lock. Another connection holds that lock
  # for the whole test; a sign-up that tried to take it would never return.
  test "a sign-up on a bootstrapped install does not wait for the bootstrap lock" do
    AppSettingsQueries.mark_admin_bootstrapped()
    user = insert(:user)
    holder = hold_bootstrap_lock()

    task = Task.async(fn -> AdminBootstrap.maybe_promote_first_user(user) end)

    try do
      assert {:ok, {:ok, returned}} = Task.yield(task, 2_000)
      refute returned.is_admin
    after
      Task.shutdown(task, :brutal_kill)
      send(holder, :release)
    end
  end

  defp hold_bootstrap_lock do
    parent = self()

    holder =
      spawn(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            AppSettingsQueries.lock_admin_bootstrap()
            send(parent, :lock_held)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :lock_held, 5_000
    holder
  end

  defp sign_up(parent, email) do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, user} =
        Repo.transaction(fn ->
          user = insert(:user, email: email)
          send(parent, {:inserted, self()})
          receive do: (:check -> :ok)

          {:ok, user} = AdminBootstrap.maybe_promote_first_user(user)
          send(parent, {:checked, self()})
          receive do: (:commit -> user)
        end)

      user
    end)
  end
end
