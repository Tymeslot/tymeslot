defmodule Tymeslot.Emails.Templates.IntegrationReauthRequired do
  @moduledoc """
  MJML email template telling a user that one of their integrations has stopped
  being usable and only reconnecting will fix it.

  Distinct from `Tymeslot.Emails.Templates.IntegrationUnhealthy`, which reports
  intermittent probe failures that may already have resolved themselves. This
  one is sent when the cause is known and permanent until the user acts: a
  revoked grant, scopes that no longer cover what Tymeslot must do, rejected
  credentials, or a calendar setup with nothing left to sync into. Saying "may
  need attention" about a certainty would understate it.

  The reason shown is the integration's stored `sync_error`: the English
  source of the sentence the dashboard shows translated, so the two cannot
  drift apart. The rest of the copy stays true for every cause, because the
  reason is the only part that varies.

  The steps follow the actions the integration's dashboard row actually has.
  A calendar row and an OAuth video row have a Reconnect button. A video
  integration holding credentials the user typed in (Jitsi, Nextcloud Talk) is
  fixed from its Edit button instead. A calendar subscription has neither: its
  feed link is the whole connection, so it is removed and subscribed to again
  with the current link.

  This is an operational alert — always rendered in English.
  """

  alias Tymeslot.Emails.Shared.{Buttons, Callouts, Styles, TemplateHelper, Text}
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
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
    %{steps: steps, button: button, action: action} = fix(integration, type, provider_label)
    subject = integration_phrase(provider_label, type_label)

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
      Tymeslot can no longer use your <strong>#{subject}</strong> integration, and it will stay that way until you #{action} it. The reason is shown above. Your existing bookings are not affected.
    </mj-text>

    #{Text.divider()}

    #{Text.title_section("What should I do?")}

    <mj-text color="#{Styles.ink_soft()}" font-size="14px" line-height="1.6">
      <ul style="padding-left: 20px; margin: 0;">
        #{html_steps(steps)}
      </ul>
    </mj-text>

    #{Buttons.action_button(@intent, button, settings_url)}

    #{Text.divider()}

    #{Text.system_footer_note(footer(action))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Reconnect required",
      "Your #{subject} integration needs reconnecting",
      intent: @intent,
      eyebrow: "Integration",
      stage_title: "Reconnect required",
      stage_subtitle: "Your #{subject} integration needs reconnecting before it can keep working."
    )
  end

  @spec render_text(user_map(), integration(), atom() | String.t()) :: String.t()
  def render_text(_user, integration, type) do
    {type_label, provider_label, settings_url} = labels(integration, type)
    reason = reason_for(integration, provider_label)
    %{steps: steps, button: button, action: action} = fix(integration, type, provider_label)
    subject = integration_phrase(provider_label, type_label)

    """
    Reconnect required

    #{reason}

    WHAT'S HAPPENING?
    Tymeslot can no longer use your #{subject} integration, and it will stay that way until you #{action} it. The reason is shown above. Your existing bookings are not affected.

    WHAT SHOULD I DO?
    #{text_steps(steps)}

    #{button}:
    #{settings_url}

    #{footer(action)}
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

  @doc """
  The provider's name as the owner knows it: the video provider's display name
  (`Nextcloud Talk`, not `Nextcloud talk`), `Calendar subscription` for a
  subscribed feed, or the humanised identifier for any other calendar or an
  unknown provider. Shared with the email's subject line.
  """
  @spec provider_label(integration(), atom() | String.t()) :: String.t()
  def provider_label(integration, :video) do
    case VideoProviderConfig.parse_known(integration.provider) do
      {:ok, provider} when provider != :none -> VideoProviderConfig.display_name(provider)
      _unknown -> humanize_provider(integration.provider)
    end
  end

  def provider_label(integration, :calendar) do
    if CalendarProviderConfig.subscription?(integration.provider),
      do: "Calendar subscription",
      else: humanize_provider(integration.provider)
  end

  def provider_label(integration, _type), do: humanize_provider(integration.provider)

  # "Zoom video", but "Calendar subscription" rather than "Calendar subscription
  # calendar".
  defp integration_phrase(provider_label, type_label) do
    if String.contains?(String.downcase(provider_label), type_label),
      do: provider_label,
      else: "#{provider_label} #{type_label}"
  end

  # The owner is not told again while the integration stays flagged: the reauth
  # email goes out when the flag is set, and the unhealthy email is withheld
  # from a flagged integration.
  defp footer(action),
    do:
      "This notification is sent when an integration needs attention. You will not receive another notice about this until you #{action} it."

  defp humanize_provider(provider),
    do: provider |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp labels(integration, type) do
    {humanize_type(type), provider_label(integration, type), settings_url_for_type(type)}
  end

  # A video integration outside the OAuth family has no Reconnect button: its
  # credentials were typed in, and they are replaced from the Edit dialog.
  defp fix(integration, :video, provider_label) do
    if VideoProviderConfig.oauth_provider?(integration.provider),
      do: reconnect_fix(provider_label),
      else: edit_fix(provider_label)
  end

  # A subscription row has no Reconnect button: a revoked feed link is replaced
  # by removing the row and subscribing again.
  defp fix(integration, :calendar, provider_label) do
    if CalendarProviderConfig.subscription?(integration.provider),
      do: subscription_fix(provider_label),
      else: reconnect_fix(provider_label)
  end

  defp fix(_integration, _type, provider_label), do: reconnect_fix(provider_label)

  defp reconnect_fix(provider_label) do
    %{
      steps: [
        "Open your integration settings",
        {"Select ", "Reconnect", " on the #{provider_label} row"},
        "Follow the steps #{provider_label} asks for"
      ],
      button: "Reconnect #{provider_label}",
      action: "reconnect"
    }
  end

  defp edit_fix(provider_label) do
    %{
      steps: [
        "Open your integration settings",
        {"Select ", "Edit", " on the #{provider_label} row"},
        "Enter the credentials again, or new ones if the old ones were revoked, and save"
      ],
      button: "Edit #{provider_label}",
      action: "update"
    }
  end

  defp subscription_fix(provider_label) do
    %{
      steps: [
        "Open your calendar settings",
        {"Select ", "Remove connection", " on the #{provider_label} row"},
        {"Choose ", "Calendar subscription", ", paste the current feed link and select Subscribe"}
      ],
      button: "Open calendar settings",
      action: "replace"
    }
  end

  defp html_steps(steps) do
    last = length(steps) - 1

    steps
    |> Enum.with_index()
    |> Enum.map_join("\n        ", fn {step, index} ->
      margin = if index == last, do: "0", else: "8px"
      ~s(<li style="margin-bottom: #{margin};">#{html_step(step)}</li>)
    end)
  end

  defp html_step({before, action, rest}), do: "#{before}<strong>#{action}</strong>#{rest}"
  defp html_step(step), do: step

  defp text_steps(steps), do: Enum.map_join(steps, "\n    ", &("- " <> text_step(&1)))

  defp text_step({before, action, rest}), do: before <> action <> rest
  defp text_step(step), do: step

  defp humanize_type(:calendar), do: "calendar"
  defp humanize_type(:video), do: "video"
  defp humanize_type(type), do: to_string(type)

  defp settings_url_for_type(:calendar),
    do: UrlBuilder.build_url("/dashboard/settings?tab=calendars")

  defp settings_url_for_type(:video), do: UrlBuilder.build_url("/dashboard/settings?tab=video")
  defp settings_url_for_type(_other), do: UrlBuilder.build_url("/dashboard/settings")
end
