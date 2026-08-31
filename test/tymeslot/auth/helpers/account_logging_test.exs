defmodule Tymeslot.Auth.Helpers.AccountLoggingTest do
  @moduledoc false

  # async: false — LogCapture attaches a global :logger handler and lowers
  # the primary Logger level for the duration of each capture.
  use ExUnit.Case, async: false

  @moduletag :auth

  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Test.LogCapture

  defp capture_at_info(fun), do: LogCapture.with_capture([logger_level: :info], fun)

  describe "identifier masking" do
    test "masks an email identifier on log_operation_failure/4, never logging it raw" do
      capture_at_info(fn ->
        AccountLogging.log_operation_failure("authentication", "alice@example.com", :not_found)
      end)

      assert_receive {:captured_log, %{meta: meta}}
      assert meta[:identifier] == "a***@example.com"
      refute inspect(meta) =~ "alice@example.com"
    end

    test "masks the email on log_user_created/2, never logging it raw" do
      capture_at_info(fn ->
        AccountLogging.log_user_created(%{id: 1, email: "bob@example.com"})
      end)

      assert_receive {:captured_log, %{meta: meta}}
      assert meta[:email] == "b***@example.com"
      refute inspect(meta) =~ "bob@example.com"
    end

    test "masks an email identifier on log_operation_success/3" do
      capture_at_info(fn ->
        AccountLogging.log_operation_success("authentication", "carol@example.com")
      end)

      assert_receive {:captured_log, %{meta: meta}}
      assert meta[:identifier] == "c***@example.com"
      refute inspect(meta) =~ "carol@example.com"
    end

    test "passes an integer user id identifier through unmasked" do
      capture_at_info(fn ->
        AccountLogging.log_operation_failure("verification", 42, :verification_failed)
      end)

      assert_receive {:captured_log, %{meta: meta}}
      assert meta[:identifier] == 42
    end

    test "drops a non-email binary identifier rather than logging it verbatim" do
      capture_at_info(fn ->
        AccountLogging.log_operation_failure(
          "email_verification",
          "raw-secret-token-value",
          :invalid_token
        )
      end)

      assert_receive {:captured_log, %{meta: meta}}
      assert meta[:identifier] == nil
      refute inspect(meta) =~ "raw-secret-token-value"
    end
  end
end
