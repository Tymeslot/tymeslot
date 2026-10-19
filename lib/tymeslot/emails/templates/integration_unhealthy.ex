defmodule Tymeslot.Emails.Templates.IntegrationUnhealthy do
  @moduledoc """
  Email telling a user that one of their integrations has been continuously
  unhealthy for more than 48 hours.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice}

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
    name = IntegrationLabels.integration_name(integration, kind)

    %{
      subject: subject(kind),
      title: dgettext("emails_integrations", "Integration may need attention"),
      preheader:
        dgettext("emails_integrations", "Your %{integration} integration may need attention",
          integration: name
        ),
      subtitle:
        dgettext(
          "emails_integrations",
          "Health probes for your %{integration} integration have been failing intermittently for 48+ hours.",
          integration: name
        ),
      eyebrow: dgettext("emails_integrations", "Integration"),
      reason:
        dgettext(
          "emails_integrations",
          "Our health checks for your %{integration} integration have been returning errors on and off for at least 48 hours. It's worth taking a look in case something needs your attention.",
          integration: name
        ),
      happening_heading: dgettext("emails_integrations", "What's happening?"),
      happening:
        {dgettext(
           "emails_integrations",
           "Our connection probes to your %{integration} integration have been failing intermittently for 48+ hours. The integration may already be working again. If it isn't, syncing and new bookings could be affected, so it's worth a quick check.",
           integration: name
         ), name},
      next_heading: dgettext("emails_integrations", "What should I do?"),
      next: [
        dgettext("emails_integrations", "Visit your integration settings to test the connection"),
        dgettext(
          "emails_integrations",
          "Check that your credentials or OAuth tokens are still valid"
        ),
        dgettext(
          "emails_integrations",
          "If you changed your password recently, you may need to reconnect the integration"
        ),
        contact_provider(kind)
      ],
      button: dgettext("emails_integrations", "Check Integration Settings"),
      settings_url: IntegrationLabels.settings_url(kind),
      footer:
        dgettext(
          "emails_integrations",
          "This notification is sent when an integration remains unhealthy for 48+ hours. It will not repeat for 30 days."
        )
    }
  end

  defp subject(:video),
    do: dgettext("emails_integrations", "Your video integration may need attention")

  defp subject(_kind),
    do: dgettext("emails_integrations", "Your calendar integration may need attention")

  defp contact_provider(:video),
    do: dgettext("emails_integrations", "Contact your video provider if the issue persists")

  defp contact_provider(_kind),
    do: dgettext("emails_integrations", "Contact your calendar provider if the issue persists")
end
