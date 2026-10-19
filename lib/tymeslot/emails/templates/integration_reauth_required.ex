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
  msgid of the sentence the dashboard shows, translated here the same way
  (`Tymeslot.Integrations.Shared.StoredReason`), so the two cannot drift
  apart. The rest of the copy stays true for every cause, because the
  reason is the only part that varies.

  The steps follow the actions the integration's dashboard row actually has.
  A calendar row and an OAuth video row have a Reconnect button. A video
  integration holding credentials the user typed in (Jitsi, Nextcloud Talk) is
  fixed from its Edit button instead. A calendar subscription has neither: its
  feed link is the whole connection, so it is removed and subscribed to again
  with the current link.

  Rendered in the recipient's locale.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice}
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Shared.StoredReason
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig

  @doc "The email, addressed and rendered in the recipient's locale."
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          IntegrationLabels.integration(),
          IntegrationLabels.kind()
        ) :: Email.t()
  def render(user, integration, kind) do
    RecipientLocale.with_user_locale(user, fn ->
      IntegrationNotice.email(user, copy(integration, kind))
    end)
  end

  defp copy(integration, kind) do
    provider = IntegrationLabels.provider_name(integration, kind)
    name = IntegrationLabels.integration_name(integration, kind)
    fix = fix(integration, kind, provider, name)

    %{
      subject:
        dgettext("emails_integrations", "Reconnect your %{provider} integration",
          provider: provider
        ),
      title: dgettext("emails_integrations", "Reconnect required"),
      preheader:
        dgettext("emails_integrations", "Your %{integration} integration needs reconnecting",
          integration: name
        ),
      subtitle:
        dgettext(
          "emails_integrations",
          "Your %{integration} integration needs reconnecting before it can keep working.",
          integration: name
        ),
      eyebrow: dgettext("emails_integrations", "Integration"),
      reason: reason_for(integration, provider),
      happening_heading: dgettext("emails_integrations", "What's happening?"),
      happening: {fix.happening, name},
      next_heading: dgettext("emails_integrations", "What should I do?"),
      next: fix.steps,
      button: fix.button,
      settings_url: IntegrationLabels.settings_url(kind),
      footer: fix.footer
    }
  end

  # The stored reason is the English msgid of the sentence the dashboard badge
  # shows, and already names the provider and the action. A blank one means
  # the flag was set by a path that recorded no diagnosis, so fall back to
  # something true rather than empty.
  defp reason_for(%{sync_error: reason}, provider) when is_binary(reason) do
    case String.trim(reason) do
      "" -> default_reason(provider)
      trimmed -> StoredReason.translate(trimmed)
    end
  end

  defp reason_for(_integration, provider), do: default_reason(provider)

  defp default_reason(provider),
    do:
      dgettext(
        "emails_integrations",
        "%{provider} needs reconnecting before Tymeslot can use it again.",
        provider: provider
      )

  # A video integration outside the OAuth family has no Reconnect button: its
  # credentials were typed in, and they are replaced from the Edit dialog.
  defp fix(integration, :video, provider, name) do
    if VideoProviderConfig.oauth_provider?(integration.provider),
      do: reconnect_fix(provider, name),
      else: edit_fix(provider, name)
  end

  # A subscription row has no Reconnect button: a revoked feed link is replaced
  # by removing the row and subscribing again.
  defp fix(integration, :calendar, provider, name) do
    if CalendarProviderConfig.subscription?(integration.provider),
      do: subscription_fix(provider, name),
      else: reconnect_fix(provider, name)
  end

  defp fix(_integration, _kind, provider, name), do: reconnect_fix(provider, name)

  # The owner is not told again while the integration stays flagged: the reauth
  # email goes out when the flag is set, and the unhealthy email is withheld
  # from a flagged integration. Each fix says so with its own verb, in whole
  # sentences so that each translates as one.
  defp reconnect_fix(provider, name) do
    %{
      happening:
        dgettext(
          "emails_integrations",
          "Tymeslot can no longer use your %{integration} integration, and it will stay that way until you reconnect it. The reason is shown above. Your existing bookings are not affected.",
          integration: name
        ),
      steps: [
        dgettext("emails_integrations", "Open your integration settings"),
        row_step(dgettext("emails_integrations", "Reconnect"), provider),
        dgettext("emails_integrations", "Follow the steps %{provider} asks for",
          provider: provider
        )
      ],
      button: dgettext("emails_integrations", "Reconnect %{provider}", provider: provider),
      footer:
        dgettext(
          "emails_integrations",
          "This notification is sent when an integration needs attention. You will not receive another notice about this until you reconnect it."
        )
    }
  end

  defp edit_fix(provider, name) do
    %{
      happening:
        dgettext(
          "emails_integrations",
          "Tymeslot can no longer use your %{integration} integration, and it will stay that way until you update it. The reason is shown above. Your existing bookings are not affected.",
          integration: name
        ),
      steps: [
        dgettext("emails_integrations", "Open your integration settings"),
        row_step(dgettext("emails_integrations", "Edit"), provider),
        dgettext(
          "emails_integrations",
          "Enter the credentials again, or new ones if the old ones were revoked, and save"
        )
      ],
      button: dgettext("emails_integrations", "Edit %{provider}", provider: provider),
      footer:
        dgettext(
          "emails_integrations",
          "This notification is sent when an integration needs attention. You will not receive another notice about this until you update it."
        )
    }
  end

  defp subscription_fix(provider, name) do
    %{
      happening:
        dgettext(
          "emails_integrations",
          "Tymeslot can no longer use your %{integration} integration, and it will stay that way until you replace it. The reason is shown above. Your existing bookings are not affected.",
          integration: name
        ),
      steps: [
        dgettext("emails_integrations", "Open your calendar settings"),
        row_step(dgettext("emails_integrations", "Delete"), provider),
        {dgettext(
           "emails_integrations",
           "Choose %{provider}, paste the current feed link and select Subscribe",
           provider: provider
         ), provider}
      ],
      button: dgettext("emails_integrations", "Open calendar settings"),
      footer:
        dgettext(
          "emails_integrations",
          "This notification is sent when an integration needs attention. You will not receive another notice about this until you replace it."
        )
    }
  end

  # `action` is the label of the row's button, set in bold.
  defp row_step(action, provider) do
    {dgettext("emails_integrations", "Select %{action} on the %{provider} row",
       action: action,
       provider: provider
     ), action}
  end
end
