defmodule Tymeslot.Auth.AuthenticationTimingTest do
  @moduledoc false

  # async: false is required: this raises the bcrypt cost factor, and that
  # config key is global to the VM, so a concurrent test would pay for it too.
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :security

  alias Tymeslot.Auth.Authentication
  alias Tymeslot.Security.Password

  import Tymeslot.Factory

  # config/test.exs pins bcrypt to 4 rounds (~2ms) to keep the suite quick,
  # which leaves the hash the same order of magnitude as scheduler noise on a
  # contended CI runner. Measured at that cost, a healthy build and one with
  # the dummy hash deleted produce overlapping ratios, so no threshold tells
  # them apart. 10 rounds costs ~60ms, which noise cannot forge in either
  # direction, and the sample count below keeps the whole test under a second.
  @log_rounds 10

  # Pairs are measured alternately rather than as two blocks: a burst of load
  # landing on one block skews that block alone, whereas a burst inside a pair
  # moves both halves together. The median then discards a pair that got hit.
  @pairs 3

  setup do
    previous = Application.get_env(:bcrypt_elixir, :log_rounds)
    Application.put_env(:bcrypt_elixir, :log_rounds, @log_rounds)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bcrypt_elixir, :log_rounds)
        rounds -> Application.put_env(:bcrypt_elixir, :log_rounds, rounds)
      end
    end)

    :ok
  end

  describe "authenticate_user/3" do
    test "an unknown address costs the same as a wrong password, hiding which accounts exist" do
      # The not-found branch must run a dummy bcrypt hash, or how quickly it
      # answers tells an attacker that no account holds that address. Nothing
      # about that hash is observable except the time it takes, so time is what
      # this measures, relative to a wrong-password check on a real account,
      # which certainly pays for bcrypt.
      hash = Password.hash_password("RealPass123!")

      # Discard one pair: the first calls pay one-off warm-up costs.
      time_wrong_password(hash)
      time_unknown_address()

      ratios = for _pair <- 1..@pairs, do: time_unknown_address() / time_wrong_password(hash)
      ratio = median(ratios)

      # Measured under deliberate CPU starvation: 0.97-1.00 with the dummy
      # hash, 0.009-0.011 without it. Both lie far from this threshold.
      assert ratio > 0.5,
             "an unknown address answered #{Float.round(ratio, 3)}x as slowly as a wrong " <>
               "password (pairs #{inspect(Enum.map(ratios, &Float.round(&1, 3)))}); the dummy " <>
               "bcrypt hash is missing, leaking which addresses have accounts"
    end
  end

  # Every sample uses a fresh address: the rate limiter keys on the email, so
  # reusing one would short-circuit into its own, much faster path.
  defp time_wrong_password(hash) do
    user = insert(:user, password_hash: hash)

    {microseconds, {:error, :invalid_password, _message}} =
      :timer.tc(fn -> Authentication.authenticate_user(user.email, "WrongPass123!") end)

    microseconds
  end

  defp time_unknown_address do
    email = "missing-#{System.unique_integer([:positive])}@example.com"

    {microseconds, {:error, :not_found, _message}} =
      :timer.tc(fn -> Authentication.authenticate_user(email, "WrongPass123!") end)

    microseconds
  end

  defp median(ratios) do
    ratios |> Enum.sort() |> Enum.at(div(length(ratios), 2))
  end
end
