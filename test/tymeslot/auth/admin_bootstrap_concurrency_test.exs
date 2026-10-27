defmodule Tymeslot.Auth.AdminBootstrapConcurrencyTest do
  @moduledoc """
  Races on the first-user admin bootstrap, on real connections.

  The sandbox cannot show a race. It gives a test one connection, so two
  "concurrent" transactions queue on it and the second always sees the first
  committed. Each contender here therefore runs on its own connection
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) and commits for real, which is
  why the module is synchronous (ExUnit runs it after every async module, with
  nothing else in flight), and why `on_exit` deletes the users it committed
  and closes the bootstrap the race tests reopen. Cleanup that other tests
  depend on lives in `on_exit`, which runs even when a timeout has killed the
  test, and every process holding a lock is linked to the test, so it dies
  with it instead of holding the settings row for the rest of the run.

  Each race is staged so that neither transaction has committed when both
  reach the contended step: both are released together, the first to finish
  it is noted, and only then are both allowed to commit. An atomic claim makes
  the second wait for the first to commit and then lose. A claim split into a
  read and a write lets both read "open" before either writes, and both win.
  The only timing involved is a bounded wait for the second contender, which
  under an atomic claim cannot finish until the first is allowed to commit.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.AppSettings.{AppSettingsQueries, AppSettingsSchema}
  alias Tymeslot.Auth.{AdminBootstrap, UserSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Test.AdminBootstrapHelpers

  # How long to wait for the second contender before letting the first
  # transaction commit.
  @second_contender_window 500

  setup do
    emails =
      for n <- 1..2, do: "first-signup-#{n}-#{System.unique_integer([:positive])}@example.com"

    # Every test starts on an established install, whatever ran before it.
    close_bootstrap!()

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(u in UserSchema, where: u.email in ^emails))
      end)

      close_bootstrap!()
    end)

    %{emails: emails}
  end

  # The property the bootstrap stands on. `only_user?` cannot mask a
  # non-atomic claim here, because no users are involved.
  test "two concurrent claims on an open bootstrap yield exactly one winner" do
    results =
      with_open_bootstrap(fn ->
        race(for _n <- 1..2, do: fn -> AppSettingsQueries.claim_admin_bootstrap() end)
      end)

    assert Enum.sort(results) == [false, true]
  end

  test "concurrent first sign-ups promote exactly one user", %{emails: emails} do
    users =
      with_open_bootstrap(fn ->
        race(
          for email <- emails do
            fn ->
              user = insert(:user, email: email)
              {:ok, user} = AdminBootstrap.maybe_promote_first_user(user)
              user
            end
          end
        )
      end)

    assert Enum.count(users, & &1.is_admin) == 1
  end

  # Every sign-up on an established install passes through here, so it must
  # not queue on the settings row. Another connection holds that row locked
  # for the whole test; a sign-up that tried to claim it would never return.
  test "a sign-up on a bootstrapped install does not wait on the settings row" do
    assert AppSettingsQueries.admin_bootstrapped?()
    user = insert(:user)
    holder = hold_settings_row()

    task = Task.async(fn -> AdminBootstrap.maybe_promote_first_user(user) end)

    try do
      # Bounded, but far longer than an unblocked sign-up takes on a loaded
      # machine: one that queued on the row would never return.
      assert {:ok, {:ok, returned}} = Task.yield(task, 10_000)
      refute returned.is_admin
    after
      Task.shutdown(task, :brutal_kill)
      send(holder, :release)
    end
  end

  # `on_exit` closes it again.
  defp with_open_bootstrap(fun) do
    Sandbox.unboxed_run(Repo, fn -> AdminBootstrapHelpers.reopen_admin_bootstrap() end)
    fun.()
  end

  defp close_bootstrap!, do: Sandbox.unboxed_run(Repo, &AdminBootstrapHelpers.close!/0)

  # Runs each step in its own committed transaction on its own connection,
  # releasing them together and committing only once the first has finished
  # and the second has had its window. Returns the steps' results.
  defp race(steps) do
    parent = self()
    tasks = Enum.map(steps, fn step -> Task.async(fn -> contend(parent, step) end) end)

    for _task <- tasks, do: assert_receive({:ready, _pid}, 10_000)
    Enum.each(tasks, &send(&1.pid, :go))

    assert_receive {:done, _first}, 10_000

    receive do
      {:done, _second} -> :ok
    after
      @second_contender_window -> :ok
    end

    Enum.each(tasks, &send(&1.pid, :commit))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp contend(parent, step) do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, result} =
        Repo.transaction(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)

          result = step.()
          send(parent, {:done, self()})
          receive do: (:commit -> result)
        end)

      result
    end)
  end

  defp hold_settings_row do
    parent = self()

    holder =
      spawn_link(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(from(s in AppSettingsSchema, where: s.id == 1, lock: "FOR UPDATE"))
            send(parent, :row_locked)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :row_locked, 10_000
    holder
  end
end
