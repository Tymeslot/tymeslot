defmodule Tymeslot.Integrations.Calendar.Shared.ErrorHandlerTest do
  use ExUnit.Case, async: false

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler
  alias Tymeslot.Test.LogCapture

  # EWS states its failures as its own response codes rather than as an HTTP
  # status, so they reach the shared vocabulary as `{:response_code, code}`.
  # Left unmapped they fall into the catch-all, which tells the account owner
  # only that something unexpected happened and logs the whole tuple as an
  # unknown error — for a failure whose cause the server named exactly.
  describe "sanitize_error_message/2 on an EWS response code" do
    test "says access was denied when the server said so" do
      message =
        ErrorHandler.sanitize_error_message({:response_code, "ErrorAccessDenied"}, :exchange)

      assert message =~ "Access denied"
      refute message =~ "unexpected"
    end

    test "keeps the generic sentence for a code with no advice attached" do
      # Asserted positively: a `refute` alone passes for every other sentence
      # in the vocabulary too, so it cannot tell the generic clause from one
      # that hands the account owner advice about a different failure.
      message =
        ErrorHandler.sanitize_error_message({:response_code, "ErrorTimeoutExpired"}, :exchange)

      assert message == "An error occurred while communicating with the calendar service."
    end

    test "logs the code itself rather than an unknown error" do
      LogCapture.attach()

      ErrorHandler.sanitize_error_message({:response_code, "ErrorTimeoutExpired"}, :exchange)

      assert_receive {:captured_log, %{level: :error, msg: msg, meta: meta}}
      assert LogCapture.message_text(msg) == "Calendar provider error"
      assert meta.error == "ErrorTimeoutExpired"
      assert meta.provider == :exchange
    end
  end

  describe "classify_and_format/3 on an EWS response code" do
    test "classifies a denied mailbox as a permission failure" do
      # The category is what callers act on, and `:unknown` routes a fixable
      # permissions problem to "try again later".
      assert {:permission, message} =
               ErrorHandler.classify_and_format({:response_code, "ErrorAccessDenied"}, :exchange)

      assert message =~ "permission"
    end

    test "classifies a mailbox that is not there as a configuration failure" do
      assert {:config, _message} =
               ErrorHandler.classify_and_format(
                 {:response_code, "ErrorNonExistentMailbox"},
                 :exchange
               )
    end

    test "classifies a mailbox address the account does not carry as a configuration failure" do
      # The one failure the Exchange provider invents rather than relays, and a
      # pure configuration problem with an exact remedy: nothing names an
      # address `GetUserAvailability` can be addressed to. `:unknown` routes it
      # to "an unexpected error occurred, please try again", which never fixes
      # it and hides that the account owner can.
      assert {:config, message} = ErrorHandler.classify_and_format(:no_mailbox_address, :exchange)

      assert message =~ "configuration"
    end

    test "leaves a code it has no advice for unknown" do
      assert {:unknown, _message} =
               ErrorHandler.classify_and_format(
                 {:response_code, "ErrorTimeoutExpired"},
                 :exchange
               )
    end
  end
end
