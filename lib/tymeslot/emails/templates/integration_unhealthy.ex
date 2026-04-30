defmodule Tymeslot.Emails.Templates.IntegrationUnhealthy do
  @moduledoc """
  MJML email template notifying a user that one of their integrations has been
  continuously unhealthy for more than 48 hours.

  This is an operational alert — always rendered in English.
  """

  alias Tymeslot.Emails.Shared.{Buttons, Callouts, Styles, TemplateHelper, Text}
  alias Tymeslot.Utils.UrlBuilder

  @intent :alert

  @spec render(
          %{
            required(:name) => String.t(),
            required(:email) => String.t(),
            optional(atom()) => term()
          },
          %{required(:provider) => atom(), optional(atom()) => term()},
          atom() | String.t()
        ) :: String.t()
  def render(_user, integration, type) do
    {type_label, provider_label, settings_url} = labels(integration, type)

    mjml_content = """
    #{Callouts.alert_box(:alert,
    "Our health checks for your #{type_label} integration (#{provider_label}) have been returning errors on and off for at least 48 hours. It's worth taking a look in case something needs your attention.",
    title: "Integration may need attention")}

    #{Text.title_section("What's happening?")}

    <mj-text
      font-size="16px"
      color="#{Styles.ink_soft()}"
      line-height="1.5"
      align="left"
      css-class="mobile-text"
    >
      Our connection probes to your <strong>#{provider_label}</strong> #{type_label} integration have been failing intermittently for 48+ hours. The integration may already be working again — but if it isn't, syncing and new bookings could be affected, so it's worth a quick check.
    </mj-text>

    #{Text.divider()}

    #{Text.title_section("What should I do?")}

    <mj-text color="#{Styles.ink_soft()}" font-size="14px" line-height="1.6">
      <ul style="padding-left: 20px; margin: 0;">
        <li style="margin-bottom: 8px;">Visit your integration settings to test the connection</li>
        <li style="margin-bottom: 8px;">Check that your credentials or OAuth tokens are still valid</li>
        <li style="margin-bottom: 8px;">If you changed your password recently, you may need to reconnect the integration</li>
        <li style="margin-bottom: 0;">Contact your #{type_label} provider if the issue persists</li>
      </ul>
    </mj-text>

    #{Buttons.action_button(@intent, "Check Integration Settings", settings_url)}

    #{Text.divider()}

    #{Text.system_footer_note("This notification is sent when an integration remains unhealthy for 48+ hours. It will not repeat for 30 days.")}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Integration may need attention",
      "Your #{provider_label} #{type_label} integration may need attention",
      intent: @intent,
      eyebrow: "Integration",
      stage_title: "Integration may need attention",
      stage_subtitle:
        "Health probes for your #{provider_label} #{type_label} integration have been failing intermittently for 48+ hours."
    )
  end

  @spec render_text(
          %{
            required(:name) => String.t(),
            required(:email) => String.t(),
            optional(atom()) => term()
          },
          %{required(:provider) => atom(), optional(atom()) => term()},
          atom() | String.t()
        ) :: String.t()
  def render_text(_user, integration, type) do
    {type_label, provider_label, settings_url} = labels(integration, type)

    """
    Integration may need attention

    Our health checks for your #{type_label} integration (#{provider_label}) have been returning errors on and off for at least 48 hours. It's worth taking a look in case something needs your attention.

    WHAT'S HAPPENING?
    Our connection probes to your #{provider_label} #{type_label} integration have been failing intermittently for 48+ hours. The integration may already be working again — but if it isn't, syncing and new bookings could be affected, so it's worth a quick check.

    WHAT SHOULD I DO?
    - Visit your integration settings to test the connection
    - Check that your credentials or OAuth tokens are still valid
    - If you changed your password recently, you may need to reconnect the integration
    - Contact your #{type_label} provider if the issue persists

    Check Integration Settings:
    #{settings_url}

    This notification is sent when an integration remains unhealthy for 48+ hours. It will not repeat for 30 days.
    """
  end

  defp labels(integration, type) do
    type_label = humanize_type(type)

    provider_label =
      integration.provider |> to_string() |> String.replace("_", " ") |> String.capitalize()

    {type_label, provider_label, settings_url_for_type(type)}
  end

  defp humanize_type(:calendar), do: "calendar"
  defp humanize_type(:video), do: "video"
  defp humanize_type(type), do: to_string(type)

  defp settings_url_for_type(:calendar),
    do: UrlBuilder.build_url("/dashboard/settings?tab=calendars")

  defp settings_url_for_type(:video), do: UrlBuilder.build_url("/dashboard/settings?tab=video")
  defp settings_url_for_type(_other), do: UrlBuilder.build_url("/dashboard/settings")
end
