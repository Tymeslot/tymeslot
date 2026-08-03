defmodule Tymeslot.Integrations.Calendar.InputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.InputValidation

  @valid_params %{
    "name" => "Work Calendar",
    "url" => "https://caldav.example.com/",
    "username" => "user@example.com",
    "password" => "secret",
    "calendar_paths" => ""
  }

  describe "validate_calendar_integration_form/1 - password special characters" do
    test "preserves password containing >" do
      params = Map.put(@valid_params, "password", "pass>word")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "pass>word"
    end

    test "preserves password containing <" do
      params = Map.put(@valid_params, "password", "pass<word")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "pass<word"
    end

    test "preserves password containing &" do
      params = Map.put(@valid_params, "password", "pass&word")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "pass&word"
    end

    test "preserves password with multiple HTML-special characters" do
      params = Map.put(@valid_params, "password", "P@ss<w0rd>&\"me\"")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "P@ss<w0rd>&\"me\""
    end

    test "preserves password with SQL-like content" do
      params = Map.put(@valid_params, "password", "pass--word")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "pass--word"
    end
  end

  describe "validate_calendar_integration_form/1 - password validation" do
    test "rejects nil password" do
      params = Map.put(@valid_params, "password", nil)

      assert {:error, %{password: _errors}} =
               InputValidation.validate_calendar_integration_form(params)
    end

    test "rejects empty password" do
      params = Map.put(@valid_params, "password", "")

      assert {:error, %{password: _errors}} =
               InputValidation.validate_calendar_integration_form(params)
    end

    test "rejects whitespace-only password" do
      params = Map.put(@valid_params, "password", "   ")

      assert {:error, %{password: _errors}} =
               InputValidation.validate_calendar_integration_form(params)
    end

    test "rejects password over 500 characters" do
      params = Map.put(@valid_params, "password", String.duplicate("a", 501))

      assert {:error, %{password: _errors}} =
               InputValidation.validate_calendar_integration_form(params)
    end

    test "accepts password of exactly 500 characters" do
      params = Map.put(@valid_params, "password", String.duplicate("a", 500))
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert String.length(result["password"]) == 500
    end
  end

  describe "validate_calendar_integration_form/1 - password edge cases" do
    test "rejects password with invalid UTF-8 encoding" do
      params = Map.put(@valid_params, "password", <<0xFF, 0xFE, 0x00>>)

      assert {:error, %{password: _errors}} =
               InputValidation.validate_calendar_integration_form(params)
    end

    test "rejects password containing null bytes" do
      params = Map.put(@valid_params, "password", "pass\x00word")

      assert {:error, %{password: _errors}} =
               InputValidation.validate_calendar_integration_form(params)
    end

    test "preserves leading and trailing whitespace in password" do
      params = Map.put(@valid_params, "password", "  secret  ")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "  secret  "
    end
  end

  describe "validate_single_field/2 - password" do
    test "preserves special characters" do
      assert {:ok, "p@ss>w0rd<&"} =
               InputValidation.validate_single_field(:password, "p@ss>w0rd<&")
    end

    test "rejects empty password" do
      assert {:error, _errors} = InputValidation.validate_single_field(:password, "")
    end
  end

  describe "validate_ics_subscription_form/2" do
    @subscription_params %{
      "name" => "My subscribed calendar",
      "url" => "https://feeds.example.com/calendar.ics"
    }

    test "accepts a valid name and feed URL" do
      assert {:ok, result} = InputValidation.validate_ics_subscription_form(@subscription_params)
      assert result["name"] == "My subscribed calendar"
      assert result["url"] == "https://feeds.example.com/calendar.ics"
    end

    test "rejects a blank URL" do
      params = Map.put(@subscription_params, "url", "")

      assert {:error, %{url: _error}} = InputValidation.validate_ics_subscription_form(params)
    end

    test "rejects a nil URL" do
      params = Map.put(@subscription_params, "url", nil)

      assert {:error, %{url: _error}} = InputValidation.validate_ics_subscription_form(params)
    end

    test "rejects a file:// scheme" do
      params = Map.put(@subscription_params, "url", "file:///etc/passwd")

      assert {:error, %{url: _error}} = InputValidation.validate_ics_subscription_form(params)
    end

    test "rejects an invalid name" do
      params = Map.put(@subscription_params, "name", "")

      assert {:error, %{name: _error}} = InputValidation.validate_ics_subscription_form(params)
    end

    test "rewrites webcal:// to https://" do
      params = Map.put(@subscription_params, "url", "webcal://feeds.example.com/calendar.ics")

      assert {:ok, result} = InputValidation.validate_ics_subscription_form(params)
      assert result["url"] == "https://feeds.example.com/calendar.ics"
    end

    test "does not crash on a non-binary url param" do
      params = Map.put(@subscription_params, "url", %{"nested" => "value"})

      assert {:error, %{url: _error}} = InputValidation.validate_ics_subscription_form(params)
    end

    test "preserves a Google-style %40-encoded secret address byte-for-byte" do
      url = "https://calendar.google.com/calendar/ical/user%40gmail.com/private-abc123/basic.ics"
      params = Map.put(@subscription_params, "url", url)

      assert {:ok, result} = InputValidation.validate_ics_subscription_form(params)
      assert result["url"] == url
    end

    test "preserves an iCloud-style token containing --" do
      url = "https://p01-caldav.icloud.com/published/2/abc--def--123"
      params = Map.put(@subscription_params, "url", url)

      assert {:ok, result} = InputValidation.validate_ics_subscription_form(params)
      assert result["url"] == url
    end

    test "preserves a token containing 0x" do
      url = "https://feeds.example.com/calendar/0xdeadbeef.ics"
      params = Map.put(@subscription_params, "url", url)

      assert {:ok, result} = InputValidation.validate_ics_subscription_form(params)
      assert result["url"] == url
    end

    test "preserves a query string with %26 and %23" do
      url = "https://feeds.example.com/calendar.ics?token=a%26b%23c"
      params = Map.put(@subscription_params, "url", url)

      assert {:ok, result} = InputValidation.validate_ics_subscription_form(params)
      assert result["url"] == url
    end

    test "accepts a webcal URL with leading whitespace" do
      params = Map.put(@subscription_params, "url", "  webcal://feeds.example.com/calendar.ics")

      assert {:ok, result} = InputValidation.validate_ics_subscription_form(params)
      assert result["url"] == "https://feeds.example.com/calendar.ics"
    end

    test "accepts WebCal:// regardless of casing" do
      params = Map.put(@subscription_params, "url", "WebCal://feeds.example.com/calendar.ics")

      assert {:ok, result} = InputValidation.validate_ics_subscription_form(params)
      assert result["url"] == "https://feeds.example.com/calendar.ics"
    end
  end
end
