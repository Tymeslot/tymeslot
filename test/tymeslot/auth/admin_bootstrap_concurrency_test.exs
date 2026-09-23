defmodule Tymeslot.Auth.AdminBootstrapConcurrencyTest do
  @moduledoc """
  Two first sign-ups racing on a fresh install: exactly one becomes admin.

  The sandbox cannot show this. It gives a test one connection, so two
  "concurrent" transactions queue on it and the second always sees the first
  committed. Each sign-up here therefore runs on its own real connection
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) and commits for real, which is
  why the module is synchronous (ExUnit runs it after every async module, with
  nothing else in flight) and why `on_exit` deletes what it committed and
  clears the bootstrap flag again.

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
  alias Tymeslot.AppSettings.AppSettingsSchema
  alias Tymeslot.Auth.{AdminBootstrap, UserSchema}
  alias Tymeslot.Repo

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

        Repo.update_all(from(s in AppSettingsSchema, where: s.id == 1),
          set: [admin_bootstrapped_at: nil]
        )
      end)
    end)

    %{emails: emails}
  end

  test "concurrent first sign-ups promote exactly one user", %{emails: emails} do
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

    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, & &1.is_admin) == 1
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
