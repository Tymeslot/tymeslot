defmodule Tymeslot.Infrastructure.StructuredLoggerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.StructuredLogger

  setup do
    original_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  describe "log_auth_event/3" do
    test "logs various auth events" do
      assert capture_log(fn ->
               StructuredLogger.log_auth_event(:login_success, 123, %{email: "test@example.com"})
             end) =~ "User logged in successfully"

      assert capture_log(fn ->
               StructuredLogger.log_auth_event(:login_failure, nil, %{reason: "invalid"})
             end) =~ "Login attempt failed"

      assert capture_log(fn ->
               StructuredLogger.log_auth_event(:logout, 123)
             end) =~ "User logged out"

      assert capture_log(fn ->
               StructuredLogger.log_auth_event(:custom_event, 123)
             end) =~ "Authentication event"
    end
  end
end
