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
  end

  defp integration(overrides \\ []) do
    Enum.into(overrides, %{
      provider: "zoom",
      sync_error: "Zoom is missing the permission needed to reschedule meetings."
    })
  end
end
