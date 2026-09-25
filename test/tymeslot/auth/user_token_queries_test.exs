defmodule Tymeslot.Auth.UserTokenQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :auth
  @moduletag :queries

  alias Tymeslot.Auth.{UserSchema, UserTokenQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, Token}

  describe "get_user_by_token/3 for a reset token, locked" do
    test "returns {:ok, user} for a valid unconsumed token" do
      user = insert(:user)
      token = Token.generate_token()
      {:ok, _stored} = UserTokenQueries.set_reset_token(user, token)

      assert {:ok, found} = UserTokenQueries.get_user_by_token(:reset, token, lock: true)
      assert found.id == user.id
    end

    test "returns {:error, :not_found} when the token has already been consumed" do
      user = insert(:user)
      token = Token.generate_token()
      {:ok, _stored} = UserTokenQueries.set_reset_token(user, token)

      # Mark the token as consumed by setting reset_token_used_at
      Repo.update_all(
        from(u in UserSchema, where: u.id == ^user.id),
        set: [reset_token_used_at: DateTime.utc_now(:second)]
      )

      assert {:error, :not_found} = UserTokenQueries.get_user_by_token(:reset, token, lock: true)
    end

    test "returns {:error, :not_found} for an unknown token" do
      assert {:error, :not_found} =
               UserTokenQueries.get_user_by_token(:reset, "unknown-token-value", lock: true)
    end

    test "locks the row it reads, so a concurrent reset cannot consume the token twice" do
      user = insert(:user)
      token = Token.generate_token()
      {:ok, _stored} = UserTokenQueries.set_reset_token(user, token)

      token_hash = Token.hash_token(token)

      queries =
        capture_repo_queries(fn ->
          assert {:ok, _found} = UserTokenQueries.get_user_by_token(:reset, token, lock: true)
        end)

      lookup =
        Enum.find_value(queries, fn {query, params} ->
          if token_hash in params, do: query
        end)

      assert lookup, "expected a token lookup query, got: #{inspect(queries)}"

      assert lookup =~ "FOR UPDATE",
             "expected the token lookup to take a row lock, got: #{lookup}"
    end
  end

  describe "consume_verification_token/1" do
    test "marks the user verified and clears the token so it cannot be reused" do
      user = insert(:user, verified_at: nil, verification_token: "one-time-token")

      assert {:ok, verified} = UserTokenQueries.consume_verification_token(user)

      assert %DateTime{} = verified.verified_at
      assert %DateTime{} = verified.verification_token_used_at
      assert verified.verification_token == nil
    end
  end

  describe "consume_reset_token/2" do
    test "sets the password, marks the token used and revokes every credential token" do
      user =
        insert(:user,
          reset_token_hash: "one-time-reset-hash",
          reset_sent_at: DateTime.utc_now(:second),
          pending_email: "pending@example.com",
          email_change_token_hash: "email-change-hash",
          email_change_sent_at: DateTime.utc_now(:second)
        )

      assert {:ok, updated} =
               UserTokenQueries.consume_reset_token(user, %{
                 password: "NewSecurePassword123!",
                 password_confirmation: "NewSecurePassword123!"
               })

      assert Password.verify_password("NewSecurePassword123!", updated.password_hash)
      assert %DateTime{} = updated.reset_token_used_at
      assert updated.reset_token_hash == nil
      assert updated.reset_sent_at == nil
      assert updated.pending_email == nil
      assert updated.email_change_token_hash == nil
      assert updated.email_change_sent_at == nil
    end

    test "rejects a password that breaks the policy and leaves the token live" do
      user = insert(:user, reset_token_hash: "one-time-reset-hash")

      assert {:error, changeset} =
               UserTokenQueries.consume_reset_token(user, %{
                 password: "weak",
                 password_confirmation: "weak"
               })

      refute changeset.valid?
      assert Repo.get!(UserSchema, user.id).reset_token_hash == "one-time-reset-hash"
    end
  end

  # The lock is only observable in the SQL the repo actually issues, so the
  # query is captured from Ecto's telemetry rather than rebuilt in the test —
  # a rebuilt query proves nothing about the one production runs.
  #
  # Ecto's telemetry is global and carries no originating pid, so this window
  # also catches every query issued by whatever else is running concurrently.
  # The params come back with the query for that reason: the caller identifies
  # its own statement by the token hash it bound, which nothing else in the VM
  # holds. Matching on the SQL text instead is not enough — a plain
  # `Repo.get(UserSchema, id)` from another async test selects the
  # `reset_token_hash` column too, and was picked up as the lookup.
  defp capture_repo_queries(fun) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      &__MODULE__.handle_repo_query/4,
      %{pid: self(), ref: ref}
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain(ref, [])
  end

  @doc false
  @spec handle_repo_query(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          %{pid: pid(), ref: reference()}
        ) :: :ok
  def handle_repo_query(_event, _measurements, metadata, %{pid: pid, ref: ref}) do
    case metadata do
      %{query: query, params: params} when is_binary(query) ->
        send(pid, {ref, {query, params}})

      _no_sql ->
        :ok
    end

    :ok
  end

  defp drain(ref, acc) do
    receive do
      {^ref, captured} -> drain(ref, [captured | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
