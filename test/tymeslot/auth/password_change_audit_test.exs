defmodule Tymeslot.Auth.PasswordChangeAuditTest do
  @moduledoc false

  # async: false is required: SecurityLogger emits at :info while config/test.exs
  # pins the primary level to :warning, so these tests lower it globally, and one
  # of them asserts on the *absence* of an event.
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :security

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Password
  alias Tymeslot.Test.LogCapture

  import Tymeslot.Factory

  setup do
    {:ok, user: insert(:user, password_hash: Password.hash_password("CurrentPass123!"))}
  end

  defp capture_at_info(fun) do
    LogCapture.with_capture([logger_level: :info], fun)
  end

  defp logged_event_types do
    LogCapture.drain()
    |> Enum.map(&LogCapture.user_metadata(&1)[:event_type])
    |> Enum.reject(&is_nil/1)
  end

  describe "authenticated password change auditing" do
    test "records a password_change entry carrying the request context", %{user: user} do
      capture_at_info(fn ->
        assert {:ok, _updated} =
                 Auth.update_user_password(
                   user,
                   "CurrentPass123!",
                   "NewPass456!",
                   "NewPass456!",
                   ip_address: "203.0.113.12",
                   user_agent: "Mozilla/5.0"
                 )
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "password_change"} = meta}}
      assert meta.user_id == user.id
      assert meta.ip_address == "203.0.113.12"
      assert meta.user_agent == "Mozilla/5.0"
    end

    test "records the entry with no context when the caller supplies none", %{user: user} do
      capture_at_info(fn ->
        assert {:ok, _updated} =
                 Auth.update_user_password(user, "CurrentPass123!", "NewPass456!", "NewPass456!")
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "password_change"} = meta}}
      assert meta.user_id == user.id
      assert meta.ip_address == nil
    end

    test "records nothing when the current password is wrong", %{user: user} do
      capture_at_info(fn ->
        assert {:error, _message} =
                 Auth.update_user_password(user, "WrongPass123!", "NewPass456!", "NewPass456!")
      end)

      refute "password_change" in logged_event_types()
      assert Password.verify_password("CurrentPass123!", reload(user).password_hash)
    end
  end

  defp reload(user), do: Repo.get!(UserSchema, user.id)
end
