defmodule Tymeslot.Emails.Templates.IntegrationPaused do
  @moduledoc """
  MJML email template notifying a user that an integration has been
  automatically paused after the configured number of days of sustained
  unhealthy status (`:auto_pause_cutoff_days`, default 14 days).

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
          atom() | String.t(),
          pos_integer()
        ) :: String.t()
  def render(_user, integration, type, cutoff_days) do
    {type_label, provider_label, settings_url} = labels(integration, type)

    mjml_content = """
    #{Callouts.alert_box(:alert,
    "We've paused your #{provider_label} #{type_label} integration after #{cutoff_days} days of failed health checks. Reconnect when you're ready and it'll resume.",
    title: "Integration paused")}

    #{Text.title_section("What's happening?")}

    <mj-text
      font-size="16px"
      color="#{Styles.ink_soft()}"
      line-height="1.5"
      align="left"
      css-class="mobile-text"
    >
      Your <strong>#{provider_label}</strong> #{type_label} integration has been failing connection checks for #{cutoff_days}+ days. We've paused it so it stops consuming resources and stops generating noise. Nothing has been deleted — your settings, calendar selections, and history are all preserved.
    </mj-text>

    #{Text.divider()}

    #{Text.title_section("How do I bring it back?")}

    <mj-text color="#{Styles.ink_soft()}" font-size="14px" line-height="1.6">
      <ul style="padding-left: 20px; margin: 0;">
        <li style="margin-bottom: 8px;">Open your integration settings</li>
        <li style="margin-bottom: 8px;">Click <strong>Reconnect</strong> and supply fresh credentials, or toggle the integration back on if the underlying issue is already fixed</li>
        <li style="margin-bottom: 0;">If you no longer need this integration, you can simply remove it</li>
      </ul>
    </mj-text>

    #{Buttons.action_button(@intent, "Open Integration Settings", settings_url)}

    #{Text.divider()}

    #{Text.system_footer_note("This is the only paused-integration notification you'll receive for this integration. Reactivating it will reset the health monitor.")}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Integration paused",
      "Your #{provider_label} #{type_label} integration has been paused",
      intent: @intent,
      eyebrow: "Integration",
      stage_title: "Integration paused",
      stage_subtitle:
        "Your #{provider_label} #{type_label} integration has been paused after #{cutoff_days} days of failed health checks."
    )
  end

  @spec render_text(
          %{
            required(:name) => String.t(),
            required(:email) => String.t(),
            optional(atom()) => term()
          },
          %{required(:provider) => atom(), optional(atom()) => term()},
          atom() | String.t(),
          pos_integer()
        ) :: String.t()
  def render_text(_user, integration, type, cutoff_days) do
    {type_label, provider_label, settings_url} = labels(integration, type)

    """
    Integration paused

    We've paused your #{provider_label} #{type_label} integration after #{cutoff_days} days of failed health checks. Reconnect when you're ready and it'll resume.

    WHAT'S HAPPENING?
    Your #{provider_label} #{type_label} integration has been failing connection checks for #{cutoff_days}+ days. We've paused it so it stops consuming resources and stops generating noise. Nothing has been deleted — your settings, calendar selections, and history are all preserved.

    HOW DO I BRING IT BACK?
    - Open your integration settings
    - Click Reconnect and supply fresh credentials, or toggle the integration back on if the underlying issue is already fixed
    - If you no longer need this integration, you can simply remove it

    Open Integration Settings:
    #{settings_url}

    This is the only paused-integration notification you'll receive for this integration. Reactivating it will reset the health monitor.
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
