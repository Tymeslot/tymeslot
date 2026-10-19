defmodule Tymeslot.Emails.Templates.IntegrationPausedTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :integrations

  alias Tymeslot.Emails.Templates.IntegrationPaused

  @user %{id: 1, email: "user@example.com", name: "Test User"}

  describe "render/4" do
    test "addresses the owner and names the calendar integration in every part" do
      email = IntegrationPaused.render(@user, %{provider: :google}, :calendar, 14)

      assert email.to == [{"Test User", "user@example.com"}]
      assert email.subject == "Your calendar integration has been paused"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "paused your Google Calendar integration after 14 days"
        assert body =~ "Open Integration Settings"
        assert body =~ "/dashboard/integrations?tab=calendars"
      end

      assert email.html_body =~ "<!doctype html>"
      assert email.html_body =~ "<strong>Google Calendar</strong> integration"
      refute email.text_body =~ "<strong>"
    end

    test "names a video integration with its kind" do
      email = IntegrationPaused.render(@user, %{provider: :zoom}, :video, 14)

      assert email.subject == "Your video integration has been paused"
      assert email.text_body =~ "Your Zoom video integration has been failing"
      assert email.html_body =~ "/dashboard/integrations?tab=video"
    end

    test "renders the configured cutoff" do
      email = IntegrationPaused.render(@user, %{provider: :zoom}, :video, 21)

      assert email.text_body =~ "after 21 days of failed health checks"
      assert email.text_body =~ "for 21+ days"
    end

    test "lists the steps in both parts" do
      email = IntegrationPaused.render(@user, %{provider: :zoom}, :video, 14)

      assert email.text_body =~
               "HOW DO I BRING IT BACK?\n- Open your integration settings\n- Click Reconnect"

      assert email.html_body =~ "Click <strong>Reconnect</strong> and supply fresh credentials"
    end

    test "addresses an owner without a name by their address" do
      email = IntegrationPaused.render(%{@user | name: nil}, %{provider: :zoom}, :video, 14)

      assert email.to == [{"user@example.com", "user@example.com"}]
    end

    test "escapes an unknown provider's identifier in the markup" do
      email = IntegrationPaused.render(@user, %{provider: :"weird<b>"}, :calendar, 14)

      assert email.text_body =~ "Weird<b> calendar"
      refute email.html_body =~ "Weird<b>"
      assert email.html_body =~ "Weird&lt;b&gt;"
    end
  end

  describe "in the recipient's language" do
    test "writes every part in German for a German-speaking owner" do
      user = Map.put(@user, :locale, "de")

      email = IntegrationPaused.render(user, %{provider: :nextcloud}, :calendar, 14)

      assert email.subject == "Ihre Kalender-Integration wurde pausiert"

      for body <- [email.html_body, email.text_body] do
        assert body =~
                 "Wir haben Ihre Integration Nextcloud-Kalender nach 14 Tagen fehlgeschlagener Statusprüfungen pausiert."

        assert body =~ "Integrationseinstellungen öffnen"
        refute body =~ "Open Integration Settings"
      end
    end
  end
end
