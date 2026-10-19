defmodule Tymeslot.Auth.AccountDeletion.RequestRaceTest do
  @moduledoc """
  The install's two admins asking to delete their accounts at once, on real
  connections staged by `Tymeslot.Test.RaceConductor` (see its moduledoc for
  why the module is synchronous and why `on_exit` deletes what it committed).

  Each request parks once it holds the admin lock. The last-admin check runs
  under that lock, so the second request waits for the first to commit, then
  finds the other admin pending deletion (which no longer counts) and is
  refused. Without the lock both read two admins, both pass, and the grace
  period ends with no admin left.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.RaceConductor

  @opts [ip: "203.0.113.7", user_agent: "ExUnit"]

  setup do
    RateLimiter.clear_all()
    started_at = DateTime.utc_now()

    admins =
      unboxed(fn -> [insert(:user, is_admin: true), insert(:user, is_admin: true)] end)

    ids = Enum.map(admins, & &1.id)

    on_exit(fn ->
      unboxed(fn ->
        # The requests queue their deletion, notice and checkout jobs for real.
        Repo.delete_all(from(j in Oban.Job, where: j.inserted_at >= ^started_at))
        Repo.delete_all(from(u in UserSchema, where: u.id in ^ids))
      end)
    end)

    RaceConductor.attach_parking()

    %{admins: admins}
  end

  test "two admins asking to delete their accounts at once leave one admin", %{
    admins: [first, second]
  } do
    results =
      race(
        for admin <- [first, second] do
          fn hold ->
            RaceConductor.arm(hold, RaceConductor.lock_of("users"))
            Auth.request_account_deletion(admin, %{"current_password" => "Password123!"}, @opts)
          end
        end
      )

    assert results |> Enum.map(&result_shape/1) |> Enum.sort() == [:pending, :refused]

    staying =
      unboxed(fn ->
        Repo.all(
          from(u in UserSchema,
            where: u.id in ^[first.id, second.id] and is_nil(u.deletion_scheduled_at)
          )
        )
      end)

    assert length(staying) == 1
  end

  defp result_shape({:ok, %UserSchema{deletion_scheduled_at: %DateTime{}}}), do: :pending
  defp result_shape({:error, %{base: _message}}), do: :refused
  defp result_shape(other), do: other
end
