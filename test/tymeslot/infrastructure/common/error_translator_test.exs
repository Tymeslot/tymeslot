defmodule Tymeslot.Infrastructure.Common.ErrorTranslatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Common.ErrorTranslator

  describe "translate_error/3" do
    test "translates :invalid_credentials" do
      result = ErrorTranslator.translate_error(:invalid_credentials, "Google")
      assert result.category == :authentication
      assert result.severity == :permanent
      assert result.support_reference == "AUTH001"
    end

    test "translates :token_expired" do
      result = ErrorTranslator.translate_error(:token_expired, "Google")
      assert result.category == :authentication
      assert result.severity == :transient
      assert result.retry_after == 5
    end

    test "translates :insufficient_permissions" do
      result =
        ErrorTranslator.translate_error(:insufficient_permissions, "Google", %{
          missing_scopes: ["calendar.read"]
        })

      assert result.category == :permission
      assert result.details =~ "calendar.read"
    end

    test "translates :timeout" do
      result = ErrorTranslator.translate_error(:timeout, "Google")
      assert result.category == :network
      assert result.severity == :transient
    end

    test "translates :connection_refused" do
      result = ErrorTranslator.translate_error(:connection_refused, "Google")
      assert result.category == :network
    end

    test "translates 5xx http errors" do
      result = ErrorTranslator.translate_error({:http_error, 500}, "Google")
      assert result.category == :server
      assert result.severity == :transient
    end

    test "translates 429 http errors" do
      result =
        ErrorTranslator.translate_error({:http_error, 429}, "Google", %{retry_after_seconds: 120})

      assert result.category == :rate_limit
      assert result.retry_after == 120

      assert "Wait 2 minutes before trying again" in result.resolution_steps
    end

    test "translates 404 http errors" do
      result = ErrorTranslator.translate_error({:http_error, 404}, "Google", %{resource: "event"})
      assert result.category == :configuration
      assert result.details =~ "event"
    end

    test "translates :invalid_base_url" do
      result = ErrorTranslator.translate_error(:invalid_base_url, "CalDAV", %{url: "invalid"})
      assert result.category == :configuration
      assert result.details =~ "invalid"
    end

    test "translates :calendar_not_found" do
      result =
        ErrorTranslator.translate_error(:calendar_not_found, "Google", %{calendar_name: "My Cal"})

      assert result.category == :configuration
      assert result.details =~ "My Cal"
    end

    test "translates :video_provider_not_configured" do
      result = ErrorTranslator.translate_error(:video_provider_not_configured, "Mirotalk")
      assert result.category == :configuration
    end

    test "translates :meeting_creation_failed" do
      result =
        ErrorTranslator.translate_error(:meeting_creation_failed, "Google Meet", %{
          reason: "Limit reached"
        })

      assert result.category == :server
      assert result.details =~ "Limit reached"
    end

    test "translates binary errors" do
      result = ErrorTranslator.translate_error("something bad", "Google")
      assert result.category == :unknown
      assert result.details =~ "something bad"
    end

    test "translates unexpected errors" do
      result = ErrorTranslator.translate_error(:weird_stuff, "Google")
      assert result.category == :unknown
      assert result.details =~ ":weird_stuff"
    end
  end

  describe "categorize_error/1" do
    test "categorizes various errors" do
      assert ErrorTranslator.categorize_error(:invalid_credentials) == :authentication
      assert ErrorTranslator.categorize_error(:timeout) == :network
      assert ErrorTranslator.categorize_error(:insufficient_permissions) == :permission
      assert ErrorTranslator.categorize_error(:calendar_not_found) == :configuration
      assert ErrorTranslator.categorize_error({:http_error, 429}) == :rate_limit
      assert ErrorTranslator.categorize_error({:http_error, 500}) == :server
      assert ErrorTranslator.categorize_error(:something_else) == :unknown
    end
  end

  describe "should_retry?/1" do
    test "returns true for transient errors with retry_after" do
      assert ErrorTranslator.should_retry?(%{severity: :transient, retry_after: 60})
    end

    test "returns false otherwise" do
      refute ErrorTranslator.should_retry?(%{severity: :permanent, retry_after: 60})
      refute ErrorTranslator.should_retry?(%{severity: :transient, retry_after: nil})
    end
  end

  describe "format_user_message/1" do
    test "formats message with details, steps and reference" do
      error = %{
        message: "Msg",
        details: "Det",
        resolution_steps: ["Step 1", "Step 2"],
        support_reference: "REF123"
      }

      formatted = ErrorTranslator.format_user_message(error)
      assert formatted =~ "Msg"
      assert formatted =~ "Det"
      assert formatted =~ "Step 1"
      assert formatted =~ "Step 2"
      assert formatted =~ "REF123"
    end
  end

  describe "duration formatting" do
    test "formats seconds, minutes, and hours" do
      # We test this through translate_error with 429
      res_45 =
        ErrorTranslator.translate_error({:http_error, 429}, "G", %{retry_after_seconds: 45})

      assert Enum.any?(res_45.resolution_steps, &(&1 =~ "45 seconds"))

      res_120 =
        ErrorTranslator.translate_error({:http_error, 429}, "G", %{retry_after_seconds: 120})

      assert Enum.any?(res_120.resolution_steps, &(&1 =~ "2 minutes"))

      res_3600 =
        ErrorTranslator.translate_error({:http_error, 429}, "G", %{retry_after_seconds: 3600})

      assert Enum.any?(res_3600.resolution_steps, &(&1 =~ "1 hour"))
    end
  end
end
