defmodule Tymeslot.Emails.Templates.IntegrationReauthRequiredTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails
  @moduletag :integrations

  alias Tymeslot.Emails.Templates.IntegrationReauthRequired

  @user %{name: "Alice", email: "alice@example.com"}

  describe "render/3" do
    test "addresses the owner and names the provider in the subject" do
      email = IntegrationReauthRequired.render(@user, integration(), :video)

      assert email.to == [{"Alice", "alice@example.com"}]
      assert email.subject == "Reconnect your Zoom integration"
    end

    test "shows the stored reason, so the email and the dashboard badge agree" do
      html = IntegrationReauthRequired.render(@user, integration(), :video).html_body

      assert html =~ "Zoom is missing the permission needed to reschedule meetings."
    end

    test "names the provider in the call to action" do
      html = IntegrationReauthRequired.render(@user, integration(), :video).html_body

      assert html =~ "Reconnect Zoom"
    end

    test "links to the video settings tab for a video integration" do
      html = IntegrationReauthRequired.render(@user, integration(), :video).html_body

      assert html =~ "/dashboard/integrations?tab=video"
    end

    test "links to the calendars tab for a calendar integration" do
      html = IntegrationReauthRequired.render(@user, integration(), :calendar).html_body

      assert html =~ "/dashboard/integrations?tab=calendars"
    end

    test "falls back to a true statement when no reason was recorded" do
      html =
        IntegrationReauthRequired.render(@user, integration(sync_error: nil), :video).html_body

      assert html =~ "Zoom needs reconnecting before Tymeslot can use it again."
    end

    test "treats a blank reason as no reason rather than rendering an empty callout" do
      html =
        IntegrationReauthRequired.render(@user, integration(sync_error: "   "), :video).html_body

      assert html =~ "Zoom needs reconnecting before Tymeslot can use it again."
    end

    test "renders a complete HTML document" do
      html = IntegrationReauthRequired.render(@user, integration(), :video).html_body

      assert html =~ "<!doctype html>"
      assert String.ends_with?(String.trim(html), "</html>")
    end
  end

  describe "render/3 for an OAuth video integration" do
    test "asks the owner to select Reconnect" do
      html = IntegrationReauthRequired.render(@user, integration(), :video).html_body

      assert html =~ "Select <strong>Reconnect</strong> on the Zoom row"
      refute html =~ "<strong>Edit</strong>"
    end
  end

  describe "render/3 for a video integration with typed-in credentials" do
    test "names the provider by its display name" do
      html = IntegrationReauthRequired.render(@user, talk_integration(), :video).html_body

      assert html =~ "Your Nextcloud Talk video integration needs reconnecting"
      refute html =~ "Nextcloud talk"
    end

    test "asks the owner to edit the integration, since its row has no Reconnect button" do
      html = IntegrationReauthRequired.render(@user, talk_integration(), :video).html_body

      assert html =~ "Select <strong>Edit</strong> on the Nextcloud Talk row"
      assert html =~ "Enter the credentials again"
      assert html =~ "Edit Nextcloud Talk"
      refute html =~ "<strong>Reconnect</strong>"
      refute html =~ "Reconnect Nextcloud Talk"
    end
  end

  describe "render/3 for a calendar subscription" do
    test "asks the owner to remove the subscription and subscribe again, since its row has no Reconnect button" do
      html = IntegrationReauthRequired.render(@user, ics_integration(), :calendar).html_body

      assert html =~ "Select <strong>Delete</strong> on the Calendar subscription row"

      assert html =~ "paste the current feed link and select Subscribe"

      assert html =~ "Open calendar settings"
      assert html =~ "Your Calendar subscription integration needs reconnecting"
      refute html =~ "<strong>Reconnect</strong>"
      refute html =~ "Ics url"
    end

    test "promises no further notice until the subscription is replaced" do
      text = IntegrationReauthRequired.render(@user, ics_integration(), :calendar).text_body

      assert text =~
               "You will not receive another notice about this until you replace it."

      refute text =~ "30 days"
    end
  end

  describe "footer" do
    test "names the action that ends the notices for each kind of row" do
      oauth = IntegrationReauthRequired.render(@user, integration(), :video).text_body
      talk = IntegrationReauthRequired.render(@user, talk_integration(), :video).text_body
      html = IntegrationReauthRequired.render(@user, talk_integration(), :video).html_body

      assert oauth =~ "You will not receive another notice about this until you reconnect it."
      assert talk =~ "You will not receive another notice about this until you update it."
      assert html =~ "until you update it"
      refute html =~ "30 days"
    end
  end

  describe "the plain text part" do
    test "carries the same reason as the HTML part" do
      text = IntegrationReauthRequired.render(@user, integration(), :video).text_body

      assert text =~ "Zoom is missing the permission needed to reschedule meetings."
      assert text =~ "Reconnect required"
      assert text =~ "/dashboard/integrations?tab=video"
    end

    test "falls back to a true statement when no reason was recorded" do
      text =
        IntegrationReauthRequired.render(@user, integration(sync_error: nil), :video).text_body

      assert text =~ "Zoom needs reconnecting before Tymeslot can use it again."
    end

    test "gives the same steps as the HTML part" do
      oauth = IntegrationReauthRequired.render(@user, integration(), :video).text_body
      talk = IntegrationReauthRequired.render(@user, talk_integration(), :video).text_body

      assert oauth =~ "- Select Reconnect on the Zoom row"
      assert talk =~ "- Select Edit on the Nextcloud Talk row"
      refute talk =~ "Reconnect Nextcloud Talk"
    end
  end

  defp ics_integration do
    %{
      provider: "ics_url",
      sync_error:
        "The calendar feed refused the stored link. Subscribe again with the current link."
    }
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

  describe "in the recipient's language" do
    test "writes every part, the stored reason included, in German" do
      user = Map.put(@user, :locale, "de")

      integration = %{
        provider: "zoom",
        sync_error:
          "Zoom is missing the permission needed to cancel meetings. Please reconnect your Zoom account."
      }

      email = IntegrationReauthRequired.render(user, integration, :video)

      assert email.subject == "Bitte verbinden Sie Ihre Integration Zoom erneut"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "Zoom fehlt die für das Absagen von Meetings erforderliche Berechtigung."
        refute body =~ "Zoom is missing the permission"
        refute body =~ "Open your integration settings"
      end

      assert email.html_body =~
               "Klicken Sie in der Zeile Zoom auf <strong>Erneut verbinden</strong>"
    end
  end
end
