defmodule Tymeslot.Webhooks.InputValidationTest do
  use Tymeslot.DataCase, async: false

  @moduletag :security

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Webhooks.InputValidation

  setup do
    RateLimiter.clear_all()
    :ok
  end

  describe "validate_webhook_form/2" do
    test "accepts valid webhook params" do
      params = %{
        "name" => "My Webhook",
        "url" => "https://example.com/webhook",
        "events" => ["meeting.created"]
      }

      assert {:ok, validated} = InputValidation.validate_webhook_form(params)
      assert validated.name == "My Webhook"
      assert validated.url == "https://example.com/webhook"
      assert validated.events == ["meeting.created"]
    end

    test "accepts multiple valid events" do
      params = %{
        "name" => "My Webhook",
        "url" => "https://example.com/hook",
        "events" => ["meeting.created", "meeting.cancelled", "meeting.rescheduled"]
      }

      assert {:ok, validated} = InputValidation.validate_webhook_form(params)
      assert length(validated.events) == 3
    end

    test "accepts empty events list" do
      params = %{
        "name" => "My Webhook",
        "url" => "https://example.com/hook",
        "events" => []
      }

      assert {:ok, _validated} = InputValidation.validate_webhook_form(params)
    end

    test "rejects missing name" do
      params = %{"url" => "https://example.com/hook", "events" => []}
      assert {:error, errors} = InputValidation.validate_webhook_form(params)
      assert Map.has_key?(errors, :name)
    end

    test "rejects missing url" do
      params = %{"name" => "My Webhook", "events" => []}
      assert {:error, errors} = InputValidation.validate_webhook_form(params)
      assert Map.has_key?(errors, :url)
    end

    test "rejects invalid url format" do
      params = %{
        "name" => "My Webhook",
        "url" => "not-a-url",
        "events" => []
      }

      assert {:error, errors} = InputValidation.validate_webhook_form(params)
      assert Map.has_key?(errors, :url)
    end

    test "rejects non-https url" do
      params = %{
        "name" => "My Webhook",
        "url" => "ftp://example.com/hook",
        "events" => []
      }

      assert {:error, errors} = InputValidation.validate_webhook_form(params)
      assert Map.has_key?(errors, :url)
    end

    test "rejects invalid event names" do
      params = %{
        "name" => "My Webhook",
        "url" => "https://example.com/hook",
        "events" => ["meeting.created", "invalid.event"]
      }

      assert {:error, errors} = InputValidation.validate_webhook_form(params)
      assert Map.has_key?(errors, :events)
    end

    test "preserves angle-bracket and quote characters in name verbatim" do
      # Webhook names are free-form text. XSS is prevented at render time by
      # Phoenix template auto-escaping; SQL injection is prevented by Ecto
      # parameterised queries. The input validator does not strip these
      # symbols so legitimate names like "Luka <> Paul" or
      # "Webhook 'Production'" round-trip unchanged.
      params = %{
        "name" => "<script>alert(1)</script>My Webhook",
        "url" => "https://example.com/hook",
        "events" => []
      }

      assert {:ok, validated} = InputValidation.validate_webhook_form(params)
      assert validated.name == "<script>alert(1)</script>My Webhook"
    end

    test "preserves SQL-comment punctuation in name verbatim" do
      params = %{
        "name" => "Webhook'; DROP TABLE webhooks; --",
        "url" => "https://example.com/hook",
        "events" => []
      }

      assert {:ok, validated} = InputValidation.validate_webhook_form(params)
      assert validated.name == "Webhook'; DROP TABLE webhooks; --"
    end

    test "preserves percent-encoded url unchanged" do
      params = %{
        "name" => "My Webhook",
        "url" => "https://example.com/hook?q=hello%20world",
        "events" => []
      }

      assert {:ok, validated} = InputValidation.validate_webhook_form(params)
      assert validated.url == "https://example.com/hook?q=hello%20world"
    end

    test "returns error when name is non-string type" do
      params = %{"name" => 42, "url" => "https://example.com/hook", "events" => []}
      assert {:error, errors} = InputValidation.validate_webhook_form(params)
      assert Map.has_key?(errors, :name)
    end

    test "returns error when url is non-string type" do
      params = %{"name" => "My Webhook", "url" => ["https://example.com"], "events" => []}
      assert {:error, errors} = InputValidation.validate_webhook_form(params)
      assert Map.has_key?(errors, :url)
    end

    test "trims whitespace-only name and rejects it" do
      params = %{"name" => "   ", "url" => "https://example.com/hook", "events" => []}
      assert {:error, errors} = InputValidation.validate_webhook_form(params)
      assert Map.has_key?(errors, :name)
    end
  end

  describe "validate_name_update/2" do
    test "accepts valid name" do
      assert {:ok, "My Webhook"} = InputValidation.validate_name_update("My Webhook")
    end

    test "rejects empty name" do
      assert {:error, _msg} = InputValidation.validate_name_update("")
    end

    test "rejects name exceeding 255 characters" do
      long_name = String.duplicate("a", 256)
      assert {:error, _msg} = InputValidation.validate_name_update(long_name)
    end

    test "preserves angle-bracket characters in name verbatim" do
      assert {:ok, "<script>alert(1)</script>My Webhook"} =
               InputValidation.validate_name_update("<script>alert(1)</script>My Webhook")
    end

    test "returns error for non-string name" do
      assert {:error, _msg} = InputValidation.validate_name_update(42)
    end
  end

  describe "validate_url_update/2" do
    test "accepts valid HTTPS url" do
      assert {:ok, "https://example.com/hook"} =
               InputValidation.validate_url_update("https://example.com/hook")
    end

    test "rejects empty url" do
      assert {:error, _msg} = InputValidation.validate_url_update("")
    end

    test "rejects invalid url" do
      assert {:error, _msg} = InputValidation.validate_url_update("not-a-url")
    end

    test "accepts url with percent-encoded characters" do
      assert {:ok, "https://example.com/hook?q=hello%20world"} =
               InputValidation.validate_url_update("https://example.com/hook?q=hello%20world")
    end

    test "returns error for non-string url" do
      assert {:error, _msg} = InputValidation.validate_url_update(:not_a_string)
    end
  end
end
