defmodule Tymeslot.Auth.PasswordResetCompositionTest do
  @moduledoc """
  End-to-end composition coverage for
  `Tymeslot.Auth.PasswordReset.initiate_reset/2` →
  `Tymeslot.Auth.PasswordReset.reset_password/3`.

  The unit suite (`password_reset_test.exs`) asserts on single-step
  behaviour (enumeration resistance, OAuth user rejection, token
  single-use, rate limiting). This file glues the two halves together:

    * initiate_reset stores a reset token **and** enqueues the password
      reset email job — asserted together so a regression in either
      side surfaces here,
    * reset_password applied to that token updates the password,
      invalidates every active session, and leaves the token unusable
      for a replay.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Ecto.Query
  import Tymeslot.Factory

  alias Tymeslot.Auth.PasswordReset
  alias Tymeslot.Auth.{UserQueries, UserSchema, UserSessionSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, RateLimiter}
  alias Tymeslot.Workers.EmailWorker

  setup do
    RateLimiter.clear_all()
    on_exit(fn -> RateLimiter.clear_all() end)
    :ok
  end

  describe "initiate_reset/2 + reset_password/3 — full pipeline" do
    test "initiate sets reset_sent_at and enqueues the reset email, then reset completes the change" do
      user =
        insert(:user,
          email: "reset-composition-#{System.unique_integer([:positive])}@example.com",
          password_hash: Password.hash_password("OldPassword123!")
        )

      session_a = insert(:user_session, user: user)
      session_b = insert(:user_session, user: user)

      assert length(sessions_for(user.id)) == 2

      # --- initiate ---
      assert {:ok, :reset_initiated, _message} = PasswordReset.initiate_reset(user.email)

      reloaded = Repo.get!(UserSchema, user.id)
      assert reloaded.reset_token_hash
      assert reloaded.reset_sent_at
      # Email job landed in the queue.
      assert [reset_job] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_password_reset", "user_id" => user.id}
               )

      raw_token = extract_token_from_url(reset_job.args["reset_url"])

      # --- reset ---
      new_password = "BrandNewPassword456!"

      assert {:ok, _user_map, _message} =
               PasswordReset.reset_password(raw_token, new_password, new_password)

      # Password actually changed.
      {:ok, final_user} = UserQueries.get_user_by_email(user.email)
      refute Password.verify_password("OldPassword123!", final_user.password_hash)
      assert Password.verify_password(new_password, final_user.password_hash)

      # Both pre-reset sessions are invalidated.
      assert sessions_for(user.id) == []
      refute Repo.get(UserSessionSchema, session_a.id)
      refute Repo.get(UserSessionSchema, session_b.id)

      # Token is now single-use; a second attempt with the same token is rejected.
      assert {:error, :invalid_token, _message} =
               PasswordReset.reset_password(raw_token, new_password, new_password)
    end

    test "OAuth user rejection short-circuits before any email is scheduled" do
      oauth_user =
        insert(:user,
          provider: "google",
          password_hash: nil,
          email: "oauth-#{System.unique_integer([:positive])}@example.com"
        )

      assert {:error, :oauth_user, _message} = PasswordReset.initiate_reset(oauth_user.email)

      # Nothing was enqueued for this user.
      assert [] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_password_reset", "user_id" => oauth_user.id}
               )
    end
  end

  defp sessions_for(user_id) do
    Repo.all(from s in UserSessionSchema, where: s.user_id == ^user_id)
  end

  defp extract_token_from_url(url) do
    url |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> List.last()
  end
end
