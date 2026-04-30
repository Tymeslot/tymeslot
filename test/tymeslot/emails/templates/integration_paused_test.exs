defmodule Tymeslot.Emails.Templates.IntegrationPausedTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.IntegrationPaused

  describe "IntegrationPaused.render/4" do
    test "generates valid HTML output for calendar type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationPaused.render(user, integration, :calendar, 14)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "generates valid HTML output for video type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      html = IntegrationPaused.render(user, integration, :video, 14)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "includes humanized provider label" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationPaused.render(user, integration, :calendar, 14)

      assert html =~ "Google calendar"
    end

    test "includes integration type in content" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      html = IntegrationPaused.render(user, integration, :video, 14)

      assert html =~ "video"
    end

    test "renders the configured cutoff_days threshold" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationPaused.render(user, integration, :calendar, 21)

      assert html =~ "21"
    end

    test "includes settings action button" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationPaused.render(user, integration, :calendar, 14)

      assert html =~ "Open Integration Settings"
    end

    test "handles unknown integration type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :custom_service}

      html = IntegrationPaused.render(user, integration, :other, 14)

      assert is_binary(html)
      assert String.length(html) > 500
    end
  end

  describe "IntegrationPaused.render_text/4" do
    test "returns plain text with provider and type details" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      text = IntegrationPaused.render_text(user, integration, :calendar, 14)

      assert text =~ "Google calendar"
      assert text =~ "calendar"
      assert text =~ "14"
      assert text =~ "Open Integration Settings"
    end

    test "handles video type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      text = IntegrationPaused.render_text(user, integration, :video, 14)

      assert text =~ "Zoom"
      assert text =~ "video"
    end

    test "includes settings URL in plain text body" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      text = IntegrationPaused.render_text(user, integration, :calendar, 14)

      assert text =~ "/dashboard/settings"
    end
  end

  describe "render_text security" do
    test "IntegrationPaused.render_text returns a valid binary with unusual provider atom" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :"weird<>provider"}

      text = IntegrationPaused.render_text(user, integration, :calendar, 14)

      assert is_binary(text)
      assert text =~ "Open Integration Settings"
    end
  end
end
