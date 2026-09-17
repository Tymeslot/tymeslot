defmodule Tymeslot.Emails.Templates.IntegrationReauthRequiredTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.IntegrationReauthRequired

  @user %{name: "Alice", email: "alice@example.com"}

  describe "render/3" do
    test "shows the stored reason, so the email and the dashboard badge agree" do
      html = IntegrationReauthRequired.render(@user, integration(), :video)

      assert html =~ "Zoom is missing the permission needed to reschedule meetings."
    end

    test "names the provider in the call to action" do
      html = IntegrationReauthRequired.render(@user, integration(), :video)

      assert html =~ "Reconnect Zoom"
    end

    test "links to the video settings tab for a video integration" do
      html = IntegrationReauthRequired.render(@user, integration(), :video)

      assert html =~ "/dashboard/settings?tab=video"
    end

    test "links to the calendars tab for a calendar integration" do
      html = IntegrationReauthRequired.render(@user, integration(), :calendar)

      assert html =~ "/dashboard/settings?tab=calendars"
    end

    test "falls back to a true statement when no reason was recorded" do
      html = IntegrationReauthRequired.render(@user, integration(sync_error: nil), :video)

      assert html =~ "Zoom needs reconnecting before Tymeslot can use it again."
    end

    test "treats a blank reason as no reason rather than rendering an empty callout" do
      html = IntegrationReauthRequired.render(@user, integration(sync_error: "   "), :video)

      assert html =~ "Zoom needs reconnecting before Tymeslot can use it again."
    end

    test "renders a complete HTML document" do
      html = IntegrationReauthRequired.render(@user, integration(), :video)

      assert html =~ "<!doctype html>"
      assert String.ends_with?(String.trim(html), "</html>")
    end
  end

  describe "render/3 for an OAuth video integration" do
    test "asks the owner to select Reconnect" do
      html = IntegrationReauthRequired.render(@user, integration(), :video)

      assert html =~ "Select <strong>Reconnect</strong> on the Zoom row"
      refute html =~ "<strong>Edit</strong>"
    end
  end

  describe "render/3 for a video integration with typed-in credentials" do
    test "names the provider by its display name" do
      html = IntegrationReauthRequired.render(@user, talk_integration(), :video)

      assert html =~ "Your Nextcloud Talk video integration needs reconnecting"
      refute html =~ "Nextcloud talk"
    end

    test "asks the owner to edit the integration, since its row has no Reconnect button" do
      html = IntegrationReauthRequired.render(@user, talk_integration(), :video)

      assert html =~ "Select <strong>Edit</strong> on the Nextcloud Talk row"
      assert html =~ "Enter the credentials again"
      assert html =~ "Edit Nextcloud Talk"
      refute html =~ "<strong>Reconnect</strong>"
      refute html =~ "Reconnect Nextcloud Talk"
    end
  end

  describe "provider_label/2" do
    test "uses the video provider's display name and humanises a calendar provider" do
      assert IntegrationReauthRequired.provider_label(%{provider: "nextcloud_talk"}, :video) ==
               "Nextcloud Talk"

      assert IntegrationReauthRequired.provider_label(%{provider: "teams"}, :video) ==
               "Microsoft Teams"

      assert IntegrationReauthRequired.provider_label(%{provider: "google"}, :calendar) ==
               "Google"
    end
  end

  describe "render_text/3" do
    test "carries the same reason as the HTML part" do
      text = IntegrationReauthRequired.render_text(@user, integration(), :video)

      assert text =~ "Zoom is missing the permission needed to reschedule meetings."
      assert text =~ "Reconnect required"
      assert text =~ "/dashboard/settings?tab=video"
    end

    test "falls back to a true statement when no reason was recorded" do
      text = IntegrationReauthRequired.render_text(@user, integration(sync_error: nil), :video)

      assert text =~ "Zoom needs reconnecting before Tymeslot can use it again."
    end

    test "gives the same steps as the HTML part" do
      oauth = IntegrationReauthRequired.render_text(@user, integration(), :video)
      talk = IntegrationReauthRequired.render_text(@user, talk_integration(), :video)

      assert oauth =~ "- Select Reconnect on the Zoom row"
      assert talk =~ "- Select Edit on the Nextcloud Talk row"
      refute talk =~ "Reconnect Nextcloud Talk"
    end
  end

  defp talk_integration do
    %{
      provider: "nextcloud_talk",
      sync_error:
        "Nextcloud refused the app password. Edit this integration and enter a new app password."
    }
  end

  defp integration(overrides \\ []) do
    Enum.into(overrides, %{
      provider: "zoom",
      sync_error: "Zoom is missing the permission needed to reschedule meetings."
    })
  end
end
