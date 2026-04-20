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
    "One of your #{type_label} integrations (#{provider_label}) has been reporting connection issues for over 48 hours. You may want to check your integration settings.",
    title: "Integration Connection Issues")}

    #{Text.title_section("What's happening?")}

    <mj-text
      font-size="16px"
      color="#{Styles.ink_soft()}"
      line-height="1.5"
      align="left"
      css-class="mobile-text"
    >
      Your <strong>#{provider_label}</strong> #{type_label} integration has been failing health checks consistently for the past 48+ hours. This may affect your ability to sync #{type_label}s or create new bookings.
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
      "Integration Connection Issues",
      "Your #{provider_label} #{type_label} integration needs attention",
      intent: @intent,
      eyebrow: "Integration",
      stage_title: "Integration needs attention",
      stage_subtitle:
        "Your #{provider_label} #{type_label} integration has been unhealthy for 48+ hours."
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
    Integration Connection Issues

    One of your #{type_label} integrations (#{provider_label}) has been reporting connection issues for over 48 hours. You may want to check your integration settings.

    WHAT'S HAPPENING?
    Your #{provider_label} #{type_label} integration has been failing health checks consistently for the past 48+ hours. This may affect your ability to sync #{type_label}s or create new bookings.

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
