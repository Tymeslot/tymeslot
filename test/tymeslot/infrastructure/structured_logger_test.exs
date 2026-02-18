defmodule Tymeslot.Infrastructure.StructuredLoggerTest do
  @moduletag :infrastructure
  use Tymeslot.DataCase, async: true
  import ExUnit.CaptureLog
  require Logger
  alias Tymeslot.Infrastructure.StructuredLogger

  setup do
  @moduletag :infrastructure
    # Temporarily set log level to :debug to capture all logs
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
               StructuredLogger.log_auth_event(:account_locked, 123)
             end) =~ "Account locked"

      assert capture_log(fn ->
               StructuredLogger.log_auth_event(:custom_event, 123)
             end) =~ "Authentication event: custom_event"
    end
  end

  describe "log_api_call/3" do
    test "logs api calls with different phases" do
      assert capture_log(fn ->
               StructuredLogger.log_api_call(:google_calendar, :request, %{method: "GET"})
             end) =~ "API request initiated"

      assert capture_log(fn ->
               StructuredLogger.log_api_call(:google_calendar, :response, %{status: 200})
             end) =~ "API request successful"

      assert capture_log(fn ->
               StructuredLogger.log_api_call(:google_calendar, :response, %{status: 404})
             end) =~ "API client error"

      assert capture_log(fn ->
               StructuredLogger.log_api_call(:google_calendar, :response, %{status: 500})
             end) =~ "API server error"

      assert capture_log(fn ->
               StructuredLogger.log_api_call(:google_calendar, :error, %{error: "timeout"})
             end) =~ "API request failed"
    end
  end

  describe "log_database_operation/3" do
    test "logs database operations" do
      assert capture_log(fn ->
               StructuredLogger.log_database_operation(:insert, :users)
             end) =~ "Database operation completed"

      assert capture_log(fn ->
               StructuredLogger.log_database_operation(:select, :users, %{duration_ms: 2000})
             end) =~ "Slow database operation"

      assert capture_log(fn ->
               StructuredLogger.log_database_operation(:delete, :users, %{error: "constraint"})
             end) =~ "Database operation failed"
    end
  end

  describe "log_business_event/2" do
    test "logs business events" do
      assert capture_log(fn ->
               StructuredLogger.log_business_event(:meeting_booked, %{meeting_id: 456})
             end) =~ "Business event: meeting_booked"
    end
  end

  describe "log_error/3" do
    test "logs errors" do
      assert capture_log(fn ->
               StructuredLogger.log_error(:internal_error, "Something broke")
             end) =~ "Something broke"
    end
  end

  describe "with_context/1" do
    test "creates a logger function with context" do
      logger = StructuredLogger.with_context(%{module: __MODULE__})
      assert is_function(logger, 3)

      assert capture_log(fn ->
               logger.(:info, "Hello", %{extra: "data"})
             end) =~ "Hello"
    end
  end

  describe "with_timing/3" do
    test "logs timing for successful operation" do
      assert capture_log(fn ->
               result = StructuredLogger.with_timing(:test_op, %{key: "val"}, fn -> :ok end)
               assert result == :ok
             end) =~ "Operation completed"
    end

    test "logs timing and reraises for failed operation" do
      assert_raise RuntimeError, "boom", fn ->
        capture_log(fn ->
          StructuredLogger.with_timing(:test_fail, %{}, fn -> raise "boom" end)
        end)
      end
    end
  end
end
