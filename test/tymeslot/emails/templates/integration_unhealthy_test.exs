defmodule Tymeslot.Emails.Templates.IntegrationUnhealthyTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.IntegrationUnhealthy

  describe "IntegrationUnhealthy.render/3" do
    test "generates valid HTML output for calendar type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert html =~ "<!doctype html>"
      assert html =~ "Integration may need attention"
      assert html =~ "Google calendar calendar integration have been failing"
      assert html =~ "Check Integration Settings"
    end

    test "generates valid HTML output for video type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      html = IntegrationUnhealthy.render(user, integration, :video)

      assert html =~ "<!doctype html>"
      assert html =~ "Integration may need attention"
      assert html =~ "Zoom video integration have been failing"
      assert html =~ "Check Integration Settings"
    end

    test "includes humanized provider label" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert html =~ "Google calendar"
    end

    test "includes integration type in content" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      html = IntegrationUnhealthy.render(user, integration, :video)

      assert html =~ "video"
    end

    test "includes connection issues warning" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert String.downcase(html) =~ "connection"
    end

    test "includes settings action button" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert html =~ "Check Integration Settings"
    end

    test "includes 48 hour threshold mention" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert html =~ "48"
    end

    test "handles unknown integration type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :custom_service}

      html = IntegrationUnhealthy.render(user, integration, :other)

      assert html =~ "<!doctype html>"
      # An unrecognised type falls back to its own string form rather than
      # dropping the provider/type wording altogether.
      assert html =~ "Custom service other integration have been failing"
      assert html =~ "Check Integration Settings"
    end
  end

  describe "IntegrationUnhealthy.render_text/3" do
    test "returns plain text with provider and type details" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      text = IntegrationUnhealthy.render_text(user, integration, :calendar)

      assert text =~ "Google calendar"
      assert text =~ "calendar"
      assert text =~ "48"
      assert text =~ "Check Integration Settings"
    end

    test "handles video type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      text = IntegrationUnhealthy.render_text(user, integration, :video)

      assert text =~ "Zoom"
      assert text =~ "video"
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input and the expected structural content is always present.

    test "IntegrationUnhealthy.render_text returns a valid binary with unusual provider atom" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :"weird<>provider"}

      text = IntegrationUnhealthy.render_text(user, integration, :calendar)

      assert text =~ "Weird<>provider"
      assert text =~ "Check Integration Settings"
    end
  end
end
