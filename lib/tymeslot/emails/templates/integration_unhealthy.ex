defmodule Tymeslot.Emails.Templates.IntegrationUnhealthy do
  @moduledoc """
  MJML email template notifying a user that one of their integrations has been
  continuously unhealthy for more than 48 hours.
  """

  alias Tymeslot.Emails.Shared.{Components, TemplateHelper}
  alias Tymeslot.Utils.UrlBuilder

  @spec render(map(), map(), atom() | String.t()) :: String.t()
  def render(_user, integration, type) do
    type_label = humanize_type(type)
    provider_label = integration.provider |> to_string() |> String.replace("_", " ") |> String.capitalize()
    settings_url = settings_url_for_type(type)

    mjml_content = """
    #{Components.alert_box("warning", "One of your #{type_label} integrations (#{provider_label}) has been reporting connection issues for over 48 hours. You may want to check your integration settings.",
      title: "Integration Connection Issues")}

    <mj-section background-color="#ffffff" border-radius="8px" padding="20px">
      <mj-column>
        #{Components.title_section("What's happening?")}

        #{Components.centered_text("Your <strong>#{provider_label}</strong> #{type_label} integration has been failing health checks consistently for the past 48+ hours. This may affect your ability to sync #{type_label}s or create new bookings.")}

        #{Components.divider()}

        #{Components.title_section("What should I do?")}

        <mj-text color="#3f3f46" font-size="14px" line-height="1.6">
          <ul style="padding-left: 20px; margin: 0;">
            <li style="margin-bottom: 8px;">Visit your integration settings to test the connection</li>
            <li style="margin-bottom: 8px;">Check that your credentials or OAuth tokens are still valid</li>
            <li style="margin-bottom: 8px;">If you changed your password recently, you may need to reconnect the integration</li>
            <li style="margin-bottom: 0;">Contact your #{type_label} provider if the issue persists</li>
          </ul>
        </mj-text>

        #{Components.action_button("Check Integration Settings", settings_url)}

        #{Components.divider()}

        #{Components.system_footer_note("This notification is sent when an integration remains unhealthy for 48+ hours. It will not repeat for 30 days.")}
      </mj-column>
    </mj-section>
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Integration Connection Issues",
      "Your #{provider_label} #{type_label} integration needs attention"
    )
  end

  defp humanize_type(:calendar), do: "calendar"
  defp humanize_type(:video), do: "video"
  defp humanize_type(type), do: to_string(type)

  defp settings_url_for_type(:calendar), do: UrlBuilder.build_url("/dashboard/settings?tab=calendars")
  defp settings_url_for_type(:video), do: UrlBuilder.build_url("/dashboard/settings?tab=video")
  defp settings_url_for_type(_other), do: UrlBuilder.build_url("/dashboard/settings")
end
