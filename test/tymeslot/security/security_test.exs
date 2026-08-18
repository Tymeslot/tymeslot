defmodule Tymeslot.Security.SecurityTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.Security

  describe "validate_url_params/1" do
    test "returns true for safe parameters" do
      params = %{"id" => "123", "name" => "John Doe"}
      assert Security.validate_url_params(params) == true
    end

    test "returns false for dangerous patterns" do
      assert Security.validate_url_params(%{"q" => "<script>alert(1)</script>"}) == false
      assert Security.validate_url_params(%{"url" => "javascript:alert(1)"}) == false
      assert Security.validate_url_params(%{"file" => "../../../etc/passwd"}) == false
      assert Security.validate_url_params(%{"input" => "line1\nline2"}) == false
    end
  end

  describe "validate_timezone/1" do
    test "accepts valid timezones" do
      assert {:ok, "Europe/Kyiv"} = Security.validate_timezone("Europe/Kyiv")
      assert {:ok, "UTC"} = Security.validate_timezone("UTC")
      assert {:ok, "Etc/UTC"} = Security.validate_timezone("Etc/UTC")
    end

    test "accepts real zones a format regex would reject" do
      # Regression: a prior format check rejected these, silently discarding the
      # visitor's choice even though the picker offers them.
      assert {:ok, _tz} = Security.validate_timezone("America/Argentina/Buenos_Aires")
      assert {:ok, _tz} = Security.validate_timezone("America/Indiana/Indianapolis")
      assert {:ok, _tz} = Security.validate_timezone("Etc/GMT+5")
    end

    test "rejects invalid formats" do
      assert {:error, "Unknown timezone"} = Security.validate_timezone("InvalidTimezone")
      assert {:error, "Unknown timezone"} = Security.validate_timezone("Europe/Kyiv/Kiev")
    end

    test "rejects an oversized string before the zone lookup" do
      assert {:error, "Timezone too long"} =
               Security.validate_timezone(String.duplicate("a", 101))
    end

    test "rejects non-string values" do
      assert {:error, "Invalid timezone"} = Security.validate_timezone(123)
    end
  end

  describe "validate_business_hours/2" do
    test "accepts time within business hours" do
      # 10:00 UTC in Europe/Kyiv (assuming no DST for simplicity, or just check the logic)
      # Actually it converts TO Europe/Kyiv.
      # If I give 10:00 AM UTC, it's 12:00 PM or 1:00 PM in Kyiv.
      {:ok, time} = Time.new(10, 0, 0)
      assert {:ok, _dt} = Security.validate_business_hours(time, "UTC")
    end

    test "rejects time outside business hours" do
      {:ok, time} = Time.new(22, 0, 0)

      assert {:error, "Time outside business hours"} =
               Security.validate_business_hours(time, "UTC")
    end

    test "rescues unexpected exceptions and logs a warning" do
      import ExUnit.CaptureLog

      # Passing a non-Time value as the first argument causes DateTime.new/3 to
      # raise a FunctionClauseError (it pattern-matches on %Time{}), exercising
      # the rescue branch that surfaces timezone-fuzzing attempts in the security log.
      log =
        capture_log(fn ->
          assert {:error, "Time validation failed"} =
                   Security.validate_business_hours("not_a_time", "UTC")
        end)

      assert log =~ "validate_business_hours"
    end
  end

  describe "validate_calendar_access/2" do
    test "allows access to current or future dates" do
      today = Date.utc_today()
      assert {:ok, ^today} = Security.validate_calendar_access(today, "user_1")

      tomorrow = Date.add(today, 1)
      assert {:ok, ^tomorrow} = Security.validate_calendar_access(tomorrow, "user_1")
    end

    test "denies access to past dates" do
      yesterday = Date.add(Date.utc_today(), -1)

      assert {:error, "Cannot query past dates"} =
               Security.validate_calendar_access(yesterday, "user_1")
    end

    test "denies access to dates too far in future" do
      way_future = Date.add(Date.utc_today(), 367)

      assert {:error, "Cannot query dates more than a year in advance"} =
               Security.validate_calendar_access(way_future, "user_1")
    end
  end

  describe "consistent_response_delay/0" do
    test "completes within reasonable time" do
      # It should sleep for 50-150ms
      {micro, :ok} = :timer.tc(fn -> Security.consistent_response_delay() end)
      assert micro >= 50_000
    end
  end

  describe "validate_domain/1" do
    test "accepts valid domains" do
      assert {:ok, "example.com"} = Security.validate_domain("example.com")
      assert {:ok, "sub.example.co.uk"} = Security.validate_domain("sub.example.co.uk")
      assert {:ok, "my-domain.com"} = Security.validate_domain("my-domain.com")
      assert {:ok, "example.co.uk"} = Security.validate_domain("example.co.uk")
      assert {:ok, "example.de"} = Security.validate_domain("example.de")
    end

    test "accepts local development hosts" do
      assert {:ok, "localhost"} = Security.validate_domain("localhost")
      assert {:ok, "127.0.0.1"} = Security.validate_domain("127.0.0.1")
      assert {:ok, "::1"} = Security.validate_domain("::1")
    end

    test "accepts 'none'" do
      assert {:ok, "none"} = Security.validate_domain("none")
    end

    test "strips protocol and accepts the bare domain" do
      assert {:ok, "example.com"} = Security.validate_domain("https://example.com")
      assert {:ok, "localhost"} = Security.validate_domain("http://localhost")
    end

    test "strips protocol, trailing slash, and path" do
      assert {:ok, "example.com"} = Security.validate_domain("https://example.com/")
      assert {:ok, "example.com"} = Security.validate_domain("https://example.com/path")
    end

    test "strips protocol and port" do
      assert {:ok, "example.com"} = Security.validate_domain("https://example.com:443")
      assert {:ok, "localhost"} = Security.validate_domain("http://localhost:4000")
    end

    test "rejects domains with paths (no protocol)" do
      assert {:error, _reason} = Security.validate_domain("example.com/path")
    end

    test "rejects domains with ports (no protocol)" do
      assert {:error, _reason} = Security.validate_domain("example.com:8080")
      assert {:error, _reason} = Security.validate_domain("localhost:4000")
    end

    test "rejects invalid formats" do
      assert {:error, _reason} = Security.validate_domain("-example.com")
      assert {:error, _reason} = Security.validate_domain("example-.com")
      assert {:error, _reason} = Security.validate_domain("example..com")
    end

    test "rejects overly long domains" do
      long_domain = String.duplicate("a", 256) <> ".com"

      assert {:error, "Some domains exceed maximum length (max 255 characters)"} =
               Security.validate_domain(long_domain)
    end
  end

  describe "validate_domain/1 TLD validation" do
    test "rejects domains with invalid TLDs" do
      {:error, msg} = Security.validate_domain("example.or")
      assert msg =~ "unrecognised"
      assert msg =~ ".or"
    end

    test "includes suggestion when confident" do
      {:error, msg} = Security.validate_domain("example.ocm")
      assert msg =~ "did you mean .com?"
    end

    test "accepts wildcard domains with valid TLDs" do
      assert {:ok, "*.example.com"} = Security.validate_domain("*.example.com")
    end

    test "rejects wildcard domains with invalid TLDs" do
      {:error, msg} = Security.validate_domain("*.example.or")
      assert msg =~ "unrecognised"
    end
  end
end
