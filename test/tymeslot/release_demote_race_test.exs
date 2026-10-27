defmodule Tymeslot.ReleaseDemoteRaceTest do
  @moduledoc """
  Two operators demoting the install's two admins at once, on real
  connections staged by `Tymeslot.Test.RaceConductor` (see its moduledoc for
  why the module is synchronous and why `on_exit` deletes what it committed).

  Each demotion parks once it holds the admin row lock. The last-admin check
  runs under that lock, so the second demotion waits for the first to commit,
  then sees one admin left and refuses. A check made before taking the lock
  lets both demotions see two admins and both commit, leaving none.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Release
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    Application.put_env(:tymeslot, :enable_admin_ui, true)

    admins =
      unboxed(fn -> [insert(:user, is_admin: true), insert(:user, is_admin: true)] end)

    ids = Enum.map(admins, & &1.id)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(u in UserSchema, where: u.id in ^ids)) end)
    end)

    RaceConductor.attach_parking()

    %{admins: admins}
  end

  test "two operators demoting the only two admins at once leave one admin", %{
    admins: [first, second]
  } do
    results =
      race(
        for admin <- [first, second] do
          fn hold ->
            RaceConductor.arm(hold, RaceConductor.lock_of("users"))
            Release.demote_admin(admin.email)
          end
        end
      )

    assert results |> Enum.map(&result_shape/1) |> Enum.sort() == [:demoted, :last_admin]

    remaining =
      unboxed(fn ->
        Repo.all(from(u in UserSchema, where: u.id in ^[first.id, second.id] and u.is_admin))
      end)

    assert length(remaining) == 1
  end

  defp result_shape({:ok, %UserSchema{is_admin: false}}), do: :demoted
  defp result_shape({:error, :last_admin}), do: :last_admin
  defp result_shape(other), do: other
end
