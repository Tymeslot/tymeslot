defmodule Tymeslot.Emails.Templates.IntegrationReauthRequired do
  @moduledoc """
  MJML email template telling a user that one of their integrations has stopped
  being usable and only reconnecting will fix it.

  Distinct from `Tymeslot.Emails.Templates.IntegrationUnhealthy`, which reports
  intermittent probe failures that may already have resolved themselves. This
  one is sent when the cause is known and permanent until the user acts: a
  revoked grant, or one whose scopes no longer cover what Tymeslot must do.
  Saying "may need attention" about a certainty would understate it.

  The reason shown is the integration's stored `sync_error`, which is the same
  sentence the dashboard badge carries, so the two cannot drift apart.

  This is an operational alert — always rendered in English.
  """

  alias Tymeslot.Emails.Shared.{Buttons, Callouts, Styles, TemplateHelper, Text}
  alias Tymeslot.Utils.UrlBuilder

  @intent :alert

  @type user_map :: %{
          required(:name) => String.t(),
          required(:email) => String.t(),
          optional(atom()) => term()
        }

  @type integration :: %{
          required(:provider) => atom() | String.t(),
          optional(atom()) => term()
        }

  @spec render(user_map(), integration(), atom() | String.t()) :: String.t()
  def render(_user, integration, type) do
    {type_label, provider_label, settings_url} = labels(integration, type)
    reason = reason_for(integration, provider_label)

    mjml_content = """
    #{Callouts.alert_box(:alert, reason, title: "Reconnect required")}

    #{Text.title_section("What's happening?")}

    <mj-text
      font-size="16px"
      color="#{Styles.ink_soft()}"
      line-height="1.5"
      align="left"
      css-class="mobile-text"
    >
      Your <strong>#{provider_label}</strong> #{type_label} integration is still connected, but the permission it was granted no longer covers everything Tymeslot needs to do on your behalf. Reconnecting re-grants it — nothing else is affected, and your existing bookings stay exactly as they are.
    </mj-text>

    #{Text.divider()}

    #{Text.title_section("What should I do?")}

    <mj-text color="#{Styles.ink_soft()}" font-size="14px" line-height="1.6">
      <ul style="padding-left: 20px; margin: 0;">
        <li style="margin-bottom: 8px;">Open your integration settings</li>
        <li style="margin-bottom: 8px;">Select <strong>Reconnect</strong> on the #{provider_label} row</li>
        <li style="margin-bottom: 0;">Approve the permissions #{provider_label} asks for</li>
      </ul>
    </mj-text>

    #{Buttons.action_button(@intent, "Reconnect #{provider_label}", settings_url)}

    #{Text.divider()}

    #{Text.system_footer_note("This notification is sent when an integration needs reconnecting. It will not repeat for 30 days.")}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Reconnect required",
      "Your #{provider_label} #{type_label} integration needs reconnecting",
      intent: @intent,
      eyebrow: "Integration",
      stage_title: "Reconnect required",
      stage_subtitle:
        "Your #{provider_label} #{type_label} integration needs reconnecting before it can keep working."
    )
  end

  @spec render_text(user_map(), integration(), atom() | String.t()) :: String.t()
  def render_text(_user, integration, type) do
    {type_label, provider_label, settings_url} = labels(integration, type)
    reason = reason_for(integration, provider_label)

    """
    Reconnect required

    #{reason}

    WHAT'S HAPPENING?
    Your #{provider_label} #{type_label} integration is still connected, but the permission it was granted no longer covers everything Tymeslot needs to do on your behalf. Reconnecting re-grants it — nothing else is affected, and your existing bookings stay exactly as they are.

    WHAT SHOULD I DO?
    - Open your integration settings
    - Select Reconnect on the #{provider_label} row
    - Approve the permissions #{provider_label} asks for

    Reconnect #{provider_label}:
    #{settings_url}

    This notification is sent when an integration needs reconnecting. It will not repeat for 30 days.
    """
  end

  # The stored reason is written for the dashboard badge and already names the
  # provider and the action. A blank one means the flag was set by a path that
  # recorded no diagnosis, so fall back to something true rather than empty.
  defp reason_for(integration, provider_label) do
    case integration do
      %{sync_error: reason} when is_binary(reason) ->
        if String.trim(reason) == "", do: default_reason(provider_label), else: reason

      _other ->
        default_reason(provider_label)
    end
  end

  defp default_reason(provider_label),
    do: "#{provider_label} needs reconnecting before Tymeslot can use it again."

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
