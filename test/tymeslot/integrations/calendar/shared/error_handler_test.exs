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

  describe "sanitize_error_message/2 for a private address" do
    # Calendar creation shows discovery's refusal through this function.
    test "names the address in the reader's language" do
      assert Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
               ErrorHandler.sanitize_error_message(:private_address, :caldav)
             end) == "Private oder lokale Netzwerkadressen sind nicht zulässig"
    end
  end

  # A provider that answered and declined the request is not a connection
  # failure; telling its owner to check the network sends them the wrong way.
  describe "a calendar's refusal" do
    test "says the calendar refused the change, not that the connection failed" do
      message = ErrorHandler.sanitize_error_message(:refused, :google)

      assert message =~ "Google Calendar refused the change"
      refute message =~ "Network"
    end

    test "is worded the same by classify_and_format/3" do
      assert {_category, message} = ErrorHandler.classify_and_format(:refused, :outlook)

      assert message =~ "refused the change"
      refute message =~ "Unable to connect"
    end
  end

  # The shared envelope names a 408 `:timeout` and an undecodable body
  # `:malformed_response`; both reach the connection test and calendar
  # creation through this function.
  describe "a timeout or an unreadable response" do
    test "a timeout says the request timed out" do
      assert ErrorHandler.sanitize_error_message(:timeout, :google) ==
               "The request timed out. Please try again."
    end

    test "an unreadable response says the service had an error" do
      message = ErrorHandler.sanitize_error_message(:malformed_response, :outlook)

      assert message == "The calendar service encountered an error. Please try again later."
    end

    test "classify_and_format/3 words both without falling back to the unknown error" do
      for reason <- [:timeout, :malformed_response] do
        {_category, message} = ErrorHandler.classify_and_format(reason, :google)
        refute message =~ "unexpected"
      end

      assert {:timeout, _message} = ErrorHandler.classify_and_format(:timeout, :google)

      assert {_category, "The calendar service encountered an error. Please try again later."} =
               ErrorHandler.classify_and_format(:malformed_response, :google)
    end
  end

  # A company calendar server reachable only on the office network or over a
  # VPN times out from Tymeslot exactly as a slow one does, and "try again"
  # sends its owner round the same loop. Only a server the owner names can be
  # such a one; a provider with a fixed address keeps the category's wording.
  describe "a timeout from a server the owner names" do
    @unreachable_advice "only reachable from your organisation's network or over a VPN"

    test "points at the network the server sits on" do
      for provider <- [:zimbra, :caldav, :nextcloud, :radicale, :baikal] do
        assert {:timeout, message} = ErrorHandler.classify_and_format(:timeout, provider)
        assert message =~ @unreachable_advice
      end

      assert {:timeout, "Zimbra did not respond in time." <> _rest} =
               ErrorHandler.classify_and_format(:timeout, :zimbra)
    end

    test "gives Exchange the same advice, since EWS reaches only an on-premises server" do
      assert {:timeout, "Exchange did not respond in time." <> rest} =
               ErrorHandler.classify_and_format(:timeout, :exchange)

      assert rest =~ @unreachable_advice
    end

    # A connection test that answers a raw reason is worded here, not by
    # `classify_and_format/3`, and must read the same.
    test "reads the same from sanitize_error_message/2" do
      for provider <- [:zimbra, :caldav, :nextcloud, :radicale, :baikal, :exchange] do
        assert {:timeout, ErrorHandler.sanitize_error_message(:timeout, provider)} ==
                 ErrorHandler.classify_and_format(:timeout, provider)
      end

      for provider <- [:apple, :mailbox_org, :google, :outlook] do
        assert ErrorHandler.sanitize_error_message(:timeout, provider) ==
                 "The request timed out. Please try again."
      end
    end

    test "keeps the category's wording for a provider with a fixed address" do
      for provider <- [:apple, :mailbox_org, :google, :outlook] do
        assert {:timeout, message} = ErrorHandler.classify_and_format(:timeout, provider)
        assert message =~ "timed out"
        refute message =~ @unreachable_advice
      end
    end
  end

  describe "classify_and_format/3 logging" do
    test "logs the failure at warning with its category and operation" do
      LogCapture.attach()

      ErrorHandler.classify_and_format(:timeout, :zimbra, %{operation: "discovery"})

      assert_receive {:captured_log, %{level: :warning, msg: msg, meta: meta}}
      assert LogCapture.message_text(msg) == "Calendar connection failed"
      assert meta.provider == :zimbra
      assert meta.category == :timeout
      assert meta.operation == "discovery"
    end
  end
end
