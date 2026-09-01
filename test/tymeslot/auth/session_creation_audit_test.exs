defmodule Tymeslot.Auth.SessionCreationAuditTest do
  @moduledoc """
  Session creation is audited in exactly one place: `Session.create_session/2`
  emits `session_created` through `SecurityLogger` on both of its branches.
  These tests hold that, and hold the two properties that make it the right
  home for the event: the plaintext session token never reaches a log record,
  and no email is required, which matters because OAuth logins hand
  `create_session/2` a user map carrying nothing but an id.

  `SecurityLogger`'s own truncation of the token is covered where it lives, in
  `Tymeslot.Security.SecurityLoggerTest`; what is checked here is the whole
  pipeline, redactor included.
  """

  # async: false is required: SecurityLogger emits at :info while config/test.exs
  # pins the primary level to :warning, so these tests lower it globally.
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :security

  alias Tymeslot.Auth.Session
  alias Tymeslot.Test.LogCapture

  import Phoenix.ConnTest
  import Tymeslot.Factory

  defp capture_at_info(fun) do
    LogCapture.with_capture([logger_level: :info], fun)
  end

  test "logs a session_created event with the token redacted" do
    user = insert(:user)

    token =
      capture_at_info(fn ->
        {:ok, _conn, token} = Session.create_session(init_test_session(build_conn(), %{}), user)
        token
      end)

    assert_receive {:captured_log, %{meta: %{event_type: "session_created"} = meta}}
    assert meta.user_id == user.id
    refute inspect(meta) =~ token
  end

  test "logs the event for a user map carrying nothing but an id" do
    user = insert(:user)

    capture_at_info(fn ->
      assert {:ok, _conn, _token} =
               Session.create_session(init_test_session(build_conn(), %{}), %{id: user.id})
    end)

    assert_receive {:captured_log, %{meta: %{event_type: "session_created"} = meta}}
    assert meta.user_id == user.id
  end
end
