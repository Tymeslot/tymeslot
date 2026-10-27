defmodule Tymeslot.Emails.Templates.IntegrationUnhealthyTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :integrations

  alias Tymeslot.Emails.Templates.IntegrationUnhealthy

  @user %{id: 1, email: "user@example.com", name: "Test User"}

  describe "render/3" do
    test "addresses the owner and names the calendar integration in every part" do
      email = IntegrationUnhealthy.render(@user, %{provider: :google}, :calendar)

      assert email.to == [{"Test User", "user@example.com"}]
      assert email.subject == "Your calendar integration may need attention"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "Our health checks for your Google Calendar integration"
        assert body =~ "for at least 48 hours"
        assert body =~ "Contact your calendar provider if the issue persists"
        assert body =~ "Check Integration Settings"
        assert body =~ "/dashboard/integrations?tab=calendars"
      end

      assert email.html_body =~ "<!doctype html>"
      assert email.html_body =~ "<strong>Google Calendar</strong> integration"
      refute email.text_body =~ "<strong>"
    end

    test "speaks of the video provider for a video integration" do
      email = IntegrationUnhealthy.render(@user, %{provider: :zoom}, :video)

      assert email.subject == "Your video integration may need attention"
      assert email.text_body =~ "probes to your Zoom video integration"
      assert email.text_body =~ "- Contact your video provider if the issue persists"
      assert email.html_body =~ "/dashboard/integrations?tab=video"
    end

    test "falls back to the provider's name for an unknown kind" do
      email = IntegrationUnhealthy.render(@user, %{provider: :custom_service}, :other)

      assert email.text_body =~ "your Custom service integration have been failing"
      assert email.html_body =~ ~r{/dashboard/integrations"}
    end

    test "escapes an unknown provider's identifier in the markup" do
      email = IntegrationUnhealthy.render(@user, %{provider: :"weird<b>"}, :calendar)

      assert email.text_body =~ "Weird<b> calendar"
      refute email.html_body =~ "Weird<b>"
    end
  end

  describe "in the recipient's language" do
    test "writes every part in German for a German-speaking owner" do
      user = Map.put(@user, :locale, "de")

      email = IntegrationUnhealthy.render(user, %{provider: :zoom}, :video)

      assert email.subject == "Ihre Video-Integration erfordert möglicherweise Aufmerksamkeit"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "Zoom-Video"
        assert body =~ "Integrationseinstellungen prüfen"
        refute body =~ "Check Integration Settings"
      end
    end
  end
end
