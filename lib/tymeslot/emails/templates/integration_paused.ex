defmodule Tymeslot.Emails.Templates.IntegrationPaused do
  @moduledoc """
  Email telling a user that an integration has been automatically paused
  after the configured number of days of sustained unhealthy status
  (`:auto_pause_cutoff_days`, default 14 days), in the user's own language.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice}

  @doc "The email, addressed and rendered in the recipient's locale."
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          IntegrationLabels.integration(),
          IntegrationLabels.kind(),
          pos_integer()
        ) :: Email.t()
  def render(user, integration, kind, cutoff_days) do
    RecipientLocale.with_user_locale(user, fn ->
      IntegrationNotice.email(user, copy(integration, kind, cutoff_days))
    end)
  end

  defp copy(integration, kind, days) do
    name = IntegrationLabels.integration_name(integration, kind)

    %{
      subject: subject(kind),
      title: dgettext("emails_integrations", "Integration paused"),
      preheader:
        dgettext("emails_integrations", "Your %{integration} integration has been paused",
          integration: name
        ),
      subtitle:
        dngettext(
          "emails_integrations",
          "Your %{integration} integration has been paused after %{count} day of failed health checks.",
          "Your %{integration} integration has been paused after %{count} days of failed health checks.",
          days,
          integration: name
        ),
      eyebrow: dgettext("emails_integrations", "Integration"),
      reason:
        dngettext(
          "emails_integrations",
          "We've paused your %{integration} integration after %{count} day of failed health checks. Reconnect when you're ready and it'll resume.",
          "We've paused your %{integration} integration after %{count} days of failed health checks. Reconnect when you're ready and it'll resume.",
          days,
          integration: name
        ),
      happening_heading: dgettext("emails_integrations", "What's happening?"),
      happening:
        {dngettext(
           "emails_integrations",
           "Your %{integration} integration has been failing connection checks for %{count}+ day. We've paused it so it stops consuming resources and stops generating noise. Nothing has been deleted: your settings, calendar selections, and history are all preserved.",
           "Your %{integration} integration has been failing connection checks for %{count}+ days. We've paused it so it stops consuming resources and stops generating noise. Nothing has been deleted: your settings, calendar selections, and history are all preserved.",
           days,
           integration: name
         ), name},
      next_heading: dgettext("emails_integrations", "How do I bring it back?"),
      next: [
        dgettext("emails_integrations", "Open your integration settings"),
        reconnect_step(),
        dgettext(
          "emails_integrations",
          "If you no longer need this integration, you can simply remove it"
        )
      ],
      button: dgettext("emails_integrations", "Open Integration Settings"),
      settings_url: IntegrationLabels.settings_url(kind),
      footer:
        dgettext(
          "emails_integrations",
          "This is the only paused-integration notification you'll receive for this integration. Reactivating it will reset the health monitor."
        )
    }
  end

  defp reconnect_step do
    action = dgettext("emails_integrations", "Reconnect")

    {dgettext(
       "emails_integrations",
       "Click %{action} and supply fresh credentials, or toggle the integration back on if the underlying issue is already fixed",
       action: action
     ), action}
  end

  defp subject(:video),
    do: dgettext("emails_integrations", "Your video integration has been paused")

  defp subject(_kind),
    do: dgettext("emails_integrations", "Your calendar integration has been paused")
end
