defmodule Tymeslot.Auth.UserTokenQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :auth
  @moduletag :queries

  alias Tymeslot.Auth.{UserSchema, UserTokenQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

  describe "get_user_by_reset_token_for_update/1" do
    test "returns {:ok, user} for a valid unconsumed token" do
      user = insert(:user)
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _stored} = UserTokenQueries.set_reset_token(user, token)

      assert {:ok, found} = UserTokenQueries.get_user_by_reset_token_for_update(token)
      assert found.id == user.id
    end

    test "returns {:error, :not_found} when the token has already been consumed" do
      user = insert(:user)
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _stored} = UserTokenQueries.set_reset_token(user, token)

      # Mark the token as consumed by setting reset_token_used_at
      Repo.update_all(
        from(u in UserSchema, where: u.id == ^user.id),
        set: [reset_token_used_at: DateTime.utc_now(:second)]
      )

      assert {:error, :not_found} = UserTokenQueries.get_user_by_reset_token_for_update(token)
    end

    test "returns {:error, :not_found} for an unknown token" do
      assert {:error, :not_found} =
               UserTokenQueries.get_user_by_reset_token_for_update("unknown-token-value")
    end

    test "locks the row it reads, so a concurrent reset cannot consume the token twice" do
      user = insert(:user)
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _stored} = UserTokenQueries.set_reset_token(user, token)

      queries =
        capture_repo_queries(fn ->
          assert {:ok, _found} = UserTokenQueries.get_user_by_reset_token_for_update(token)
        end)

      lookup =
        Enum.find(queries, &(&1 =~ "reset_token_hash" and &1 =~ ~r/^SELECT/i))

      assert lookup, "expected a token lookup query, got: #{inspect(queries)}"

      assert lookup =~ "FOR UPDATE",
             "expected the token lookup to take a row lock, got: #{lookup}"
    end
  end

  # The lock is only observable in the SQL the repo actually issues, so the
  # query is captured from Ecto's telemetry rather than rebuilt in the test —
  # a rebuilt query proves nothing about the one production runs.
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
      %{query: query} when is_binary(query) -> send(pid, {ref, query})
      _no_sql -> :ok
    end

    :ok
  end

  defp drain(ref, acc) do
    receive do
      {^ref, query} -> drain(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
