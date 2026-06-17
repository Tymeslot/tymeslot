defmodule Tymeslot.Slack.InputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :slack
  @moduletag :unit

  alias Tymeslot.Slack.InputValidation

  # ---------------------------------------------------------------------------
  # validate_name/3
  # ---------------------------------------------------------------------------

  describe "validate_name/3" do
    test "accepts a valid name" do
      {name, errors} = InputValidation.validate_name("My Slack", %{}, true)
      assert name == "My Slack"
      assert errors == %{}
    end

    test "rejects empty string when required" do
      {nil, errors} = InputValidation.validate_name("", %{}, true)
      assert Map.has_key?(errors, :name)
    end

    test "rejects nil when required" do
      {nil, errors} = InputValidation.validate_name(nil, %{}, true)
      assert Map.has_key?(errors, :name)
    end

    test "accepts nil when not required" do
      {nil, errors} = InputValidation.validate_name(nil, %{}, false)
      assert errors == %{}
    end

    test "accepts empty string when not required" do
      {nil, errors} = InputValidation.validate_name("", %{}, false)
      assert errors == %{}
    end

    test "rejects names over the 80-character maximum" do
      long_name = String.duplicate("a", 81)
      {nil, errors} = InputValidation.validate_name(long_name, %{}, true)
      assert Map.has_key?(errors, :name)
    end

    test "accepts unicode names within length limit" do
      {name, errors} = InputValidation.validate_name("日本語通知", %{}, true)
      assert is_binary(name)
      assert errors == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # validate_events/2
  # ---------------------------------------------------------------------------

  describe "validate_events/2" do
    test "rejects nil" do
      {nil, errors} = InputValidation.validate_events(nil, %{})
      assert Map.has_key?(errors, :events)
    end

    test "rejects an empty list" do
      {nil, errors} = InputValidation.validate_events([], %{})
      assert Map.has_key?(errors, :events)
    end

    test "accepts a valid list of event names" do
      {events, errors} = InputValidation.validate_events(["meeting.created"], %{})
      assert events == ["meeting.created"]
      assert errors == %{}
    end

    test "accepts all known valid events together" do
      valid = ["meeting.created", "meeting.cancelled", "meeting.rescheduled"]
      {events, errors} = InputValidation.validate_events(valid, %{})
      assert events == valid
      assert errors == %{}
    end

    test "rejects a list containing invalid event names" do
      {nil, errors} = InputValidation.validate_events(["bogus.event"], %{})
      assert Map.has_key?(errors, :events)
    end

    test "rejects a mixed list where one event is invalid" do
      {nil, errors} = InputValidation.validate_events(["meeting.created", "bad.event"], %{})
      assert Map.has_key?(errors, :events)
    end
  end

  # ---------------------------------------------------------------------------
  # validate_webhook_url/2
  # ---------------------------------------------------------------------------

  describe "validate_webhook_url/2" do
    test "rejects nil" do
      {nil, errors} = InputValidation.validate_webhook_url(nil, %{})
      assert Map.has_key?(errors, :webhook_url)
    end

    test "rejects empty string" do
      {nil, errors} = InputValidation.validate_webhook_url("", %{})
      assert Map.has_key?(errors, :webhook_url)
    end

    test "accepts a valid https://hooks.slack.com/services/... URL" do
      url = "https://hooks.slack.com/services/TABC123/BABC123/sometoken123"
      {accepted, errors} = InputValidation.validate_webhook_url(url, %{})
      assert accepted == url
      assert errors == %{}
    end

    test "rejects a non-Slack host" do
      {nil, errors} =
        InputValidation.validate_webhook_url("https://hooks.example.com/services/T/B/abc", %{})

      assert Map.has_key?(errors, :webhook_url)
    end

    test "rejects an HTTP (non-HTTPS) Slack URL" do
      {nil, errors} =
        InputValidation.validate_webhook_url(
          "http://hooks.slack.com/services/TABC/BABC/token",
          %{}
        )

      assert Map.has_key?(errors, :webhook_url)
    end

    test "rejects a malformed URL" do
      {nil, errors} = InputValidation.validate_webhook_url("not-a-url", %{})
      assert Map.has_key?(errors, :webhook_url)
    end

    test "trims surrounding whitespace before validation" do
      url = "  https://hooks.slack.com/services/TABC123/BABC123/sometoken123  "
      {accepted, errors} = InputValidation.validate_webhook_url(url, %{})
      assert accepted == String.trim(url)
      assert errors == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # validate_channel_hint/2
  # ---------------------------------------------------------------------------

  describe "validate_channel_hint/2" do
    test "accepts nil (hint is optional)" do
      {nil, errors} = InputValidation.validate_channel_hint(nil, %{})
      assert errors == %{}
    end

    test "accepts empty string (hint is optional)" do
      {nil, errors} = InputValidation.validate_channel_hint("", %{})
      assert errors == %{}
    end

    test "accepts a valid channel hint" do
      {hint, errors} = InputValidation.validate_channel_hint("#general", %{})
      assert is_binary(hint)
      assert errors == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # validate_channel_id/2
  # ---------------------------------------------------------------------------

  describe "validate_channel_id/2" do
    test "rejects nil" do
      {nil, errors} = InputValidation.validate_channel_id(nil, %{})
      assert Map.has_key?(errors, :channel_id)
    end

    test "rejects empty string" do
      {nil, errors} = InputValidation.validate_channel_id("", %{})
      assert Map.has_key?(errors, :channel_id)
    end

    test "accepts a valid channel ID" do
      {id, errors} = InputValidation.validate_channel_id("C012AB3CD", %{})
      assert id == "C012AB3CD"
      assert errors == %{}
    end

    test "trims surrounding whitespace" do
      {id, errors} = InputValidation.validate_channel_id("  C012AB3CD  ", %{})
      assert id == "C012AB3CD"
      assert errors == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # validate_channel_name/2
  # ---------------------------------------------------------------------------

  describe "validate_channel_name/2" do
    test "accepts nil (name is optional)" do
      {nil, errors} = InputValidation.validate_channel_name(nil, %{})
      assert errors == %{}
    end

    test "accepts empty string (name is optional)" do
      {nil, errors} = InputValidation.validate_channel_name("", %{})
      assert errors == %{}
    end

    test "accepts a valid channel name and trims it" do
      {name, errors} = InputValidation.validate_channel_name("  general  ", %{})
      assert name == "general"
      assert errors == %{}
    end

    test "strips a leading '#' from the channel name" do
      {name, errors} = InputValidation.validate_channel_name("#bookings", %{})
      assert name == "bookings"
      assert errors == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # validate_form/2
  # ---------------------------------------------------------------------------

  describe "validate_form/2" do
    test "happy path: webhook_url mode returns sanitised params" do
      params = %{
        "name" => "My Notifications",
        "webhook_url" => "https://hooks.slack.com/services/TABC123/BABC123/tok",
        "webhook_channel_hint" => "#general",
        "events" => ["meeting.created"]
      }

      assert {:ok, sanitized} = InputValidation.validate_form(params, mode: :webhook_url)
      assert sanitized.name == "My Notifications"
      assert sanitized.webhook_url =~ "hooks.slack.com"
      assert sanitized.events == ["meeting.created"]
    end

    test "happy path: oauth_pending mode requires only channel_id and events" do
      params = %{
        "channel_id" => "C123",
        "channel_name" => "bookings",
        "events" => ["meeting.created", "meeting.cancelled"]
      }

      assert {:ok, sanitized} = InputValidation.validate_form(params, mode: :oauth_pending)
      assert sanitized.channel_id == "C123"
      assert sanitized.events == ["meeting.created", "meeting.cancelled"]
      # name is not required in oauth_pending mode
      refute Map.has_key?(sanitized, :name)
    end

    test "aggregated error path: webhook_url mode with missing required fields" do
      assert {:error, errors} = InputValidation.validate_form(%{}, mode: :webhook_url)
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :webhook_url)
      assert Map.has_key?(errors, :events)
    end

    test "aggregated error path: oauth_pending mode with missing channel_id" do
      params = %{"events" => ["meeting.created"]}

      assert {:error, errors} = InputValidation.validate_form(params, mode: :oauth_pending)
      assert Map.has_key?(errors, :channel_id)
    end

    test "webhook_url_existing mode: blank webhook_url is allowed (keep current)" do
      params = %{
        "name" => "Edited",
        "webhook_url" => "",
        "events" => ["meeting.created"]
      }

      assert {:ok, sanitized} = InputValidation.validate_form(params, mode: :webhook_url_existing)
      # The blank URL is omitted so the stored encrypted value is preserved.
      refute Map.has_key?(sanitized, :webhook_url)
      assert sanitized.name == "Edited"
    end

    test "webhook_url_existing mode: a provided URL is still format-validated" do
      bad = %{
        "name" => "Edited",
        "webhook_url" => "https://evil.example",
        "events" => ["meeting.created"]
      }

      assert {:error, errors} = InputValidation.validate_form(bad, mode: :webhook_url_existing)
      assert Map.has_key?(errors, :webhook_url)

      good = %{
        "name" => "Edited",
        "webhook_url" => "https://hooks.slack.com/services/TABC123/BABC123/tok",
        "events" => ["meeting.created"]
      }

      assert {:ok, sanitized} = InputValidation.validate_form(good, mode: :webhook_url_existing)
      assert sanitized.webhook_url =~ "hooks.slack.com"
    end
  end
end
