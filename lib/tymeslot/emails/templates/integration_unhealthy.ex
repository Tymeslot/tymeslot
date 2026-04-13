defmodule Tymeslot.Emails.Templates.IntegrationUnhealthy do
  @moduledoc """
  MJML email template notifying a user that one of their integrations has been
  continuously unhealthy for more than 48 hours.
  """

  alias Tymeslot.Emails.Shared.{Buttons, Callouts, Styles, TemplateHelper, Text}
  alias Tymeslot.Utils.UrlBuilder

  use Gettext, backend: TymeslotWeb.Gettext

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
    dgettext("emails",
    "One of your %{type} integrations (%{provider}) has been reporting connection issues for over 48 hours. You may want to check your integration settings.",
    type: type_label,
    provider: provider_label),
    title: dgettext("emails", "Integration Connection Issues"))}

    #{Text.title_section(dgettext("emails", "What's happening?"))}

    <mj-text
      font-size="16px"
      color="#{Styles.ink_soft()}"
      line-height="1.5"
      align="left"
      css-class="mobile-text"
    >
      #{dgettext("emails", "Your <strong>%{provider}</strong> %{type} integration has been failing health checks consistently for the past 48+ hours. This may affect your ability to sync %{type}s or create new bookings.", provider: provider_label, type: type_label)}
    </mj-text>

    #{Text.divider()}

    #{Text.title_section(dgettext("emails", "What should I do?"))}

    <mj-text color="#{Styles.ink_soft()}" font-size="14px" line-height="1.6">
      <ul style="padding-left: 20px; margin: 0;">
        <li style="margin-bottom: 8px;">#{dgettext("emails", "Visit your integration settings to test the connection")}</li>
        <li style="margin-bottom: 8px;">#{dgettext("emails", "Check that your credentials or OAuth tokens are still valid")}</li>
        <li style="margin-bottom: 8px;">#{dgettext("emails", "If you changed your password recently, you may need to reconnect the integration")}</li>
        <li style="margin-bottom: 0;">#{dgettext("emails", "Contact your %{type} provider if the issue persists", type: type_label)}</li>
      </ul>
    </mj-text>

    #{Buttons.action_button(@intent, dgettext("emails", "Check Integration Settings"), settings_url)}

    #{Text.divider()}

    #{Text.system_footer_note(dgettext("emails", "This notification is sent when an integration remains unhealthy for 48+ hours. It will not repeat for 30 days."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Integration Connection Issues"),
      dgettext("emails", "Your %{provider} %{type} integration needs attention",
        provider: provider_label,
        type: type_label
      ),
      intent: @intent,
      eyebrow: dgettext("emails", "Integration"),
      stage_title: dgettext("emails", "Integration needs attention"),
      stage_subtitle:
        dgettext(
          "emails",
          "Your %{provider} %{type} integration has been unhealthy for 48+ hours.",
          provider: provider_label,
          type: type_label
        )
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
    #{dgettext("emails", "Integration Connection Issues")}

    #{dgettext("emails", "One of your %{type} integrations (%{provider}) has been reporting connection issues for over 48 hours. You may want to check your integration settings.", type: type_label, provider: provider_label)}

    #{dgettext("emails", "WHAT'S HAPPENING?")}
    #{dgettext("emails", "Your %{provider} %{type} integration has been failing health checks consistently for the past 48+ hours. This may affect your ability to sync %{type}s or create new bookings.", provider: provider_label, type: type_label)}

    #{dgettext("emails", "WHAT SHOULD I DO?")}
    - #{dgettext("emails", "Visit your integration settings to test the connection")}
    - #{dgettext("emails", "Check that your credentials or OAuth tokens are still valid")}
    - #{dgettext("emails", "If you changed your password recently, you may need to reconnect the integration")}
    - #{dgettext("emails", "Contact your %{type} provider if the issue persists", type: type_label)}

    #{dgettext("emails", "Check Integration Settings:")}
    #{settings_url}

    #{dgettext("emails", "This notification is sent when an integration remains unhealthy for 48+ hours. It will not repeat for 30 days.")}
    """
  end

  defp labels(integration, type) do
    type_label = humanize_type(type)

    provider_label =
      integration.provider |> to_string() |> String.replace("_", " ") |> String.capitalize()

    {type_label, provider_label, settings_url_for_type(type)}
  end

  defp humanize_type(:calendar), do: dgettext("emails", "calendar")
  defp humanize_type(:video), do: dgettext("emails", "video")
  defp humanize_type(type), do: to_string(type)

  defp settings_url_for_type(:calendar),
    do: UrlBuilder.build_url("/dashboard/settings?tab=calendars")

  defp settings_url_for_type(:video), do: UrlBuilder.build_url("/dashboard/settings?tab=video")
  defp settings_url_for_type(_other), do: UrlBuilder.build_url("/dashboard/settings")
end
