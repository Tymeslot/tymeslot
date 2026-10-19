defmodule Tymeslot.Emails.Templates.CalendarsRemoved do
  @moduledoc """
  MJML email template telling the owner of a calendar integration that the
  calendar server no longer has one or more of the calendars Tymeslot used,
  so Tymeslot has stopped using them.

  One email per deselection, listing every calendar that deselection
  removed; the dashboard shows the same notice until the owner dismisses it
  (see `Tymeslot.Integrations.Calendar.RemovedCalendars`).

  Rendered in the owner's locale.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice}

  @doc """
  The email naming every calendar in `calendars`, addressed and rendered in
  the recipient's locale.
  """
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          %{required(:name) => String.t(), optional(atom()) => term()},
          [String.t(), ...]
        ) :: Email.t()
  def render(user, integration, [_first | _rest] = calendars) do
    RecipientLocale.with_user_locale(user, fn ->
      IntegrationNotice.email(user, copy(integration, calendars))
    end)
  end

  defp subject([calendar]) do
    dgettext("emails_integrations", "“%{calendar}” is no longer on your calendar server",
      calendar: calendar
    )
  end

  defp subject(calendars) do
    dngettext(
      "emails_integrations",
      "%{count} calendar is no longer on your calendar server",
      "%{count} calendars are no longer on your calendar server",
      length(calendars)
    )
  end

  defp copy(integration, calendars) do
    count = length(calendars)

    subject = subject(calendars)

    %{
      subject: subject,
      preheader: subject,
      subtitle: subject,
      eyebrow: dgettext("emails_integrations", "Integration"),
      reason_items: list_items(calendars),
      title:
        dngettext(
          "emails_integrations",
          "Calendar no longer available",
          "Calendars no longer available",
          count
        ),
      reason: reason(calendars),
      happening_heading: dgettext("emails_integrations", "What's happening?"),
      happening:
        dngettext(
          "emails_integrations",
          "Tymeslot checked %{integration} and the server no longer has the calendar listed above. This usually means it was deleted, or stopped being shared with you, on the server. Your other calendars on %{integration} are unaffected.",
          "Tymeslot checked %{integration} and the server no longer has the calendars listed above. This usually means they were deleted, or stopped being shared with you, on the server. Your other calendars on %{integration} are unaffected.",
          count,
          integration: integration.name
        ),
      next_heading: dgettext("emails_integrations", "What should I do?"),
      next:
        dngettext(
          "emails_integrations",
          "If you removed it on purpose, there is nothing to do. If not, restore it on your calendar server, then select it again in your calendar settings.",
          "If you removed them on purpose, there is nothing to do. If not, restore them on your calendar server, then select them again in your calendar settings.",
          count
        ),
      button: dgettext("emails_integrations", "Open calendar settings"),
      settings_url: IntegrationLabels.settings_url(:calendar),
      footer:
        dgettext(
          "emails_integrations",
          "You get this email once each time a calendar disappears. The notice in your calendar settings stays until you dismiss it."
        )
    }
  end

  defp reason([calendar]) do
    dgettext(
      "emails_integrations",
      "“%{calendar}” is no longer on your calendar server, so Tymeslot has stopped using it.",
      calendar: calendar
    )
  end

  defp reason(_calendars) do
    dgettext(
      "emails_integrations",
      "These calendars are no longer on your calendar server, so Tymeslot has stopped using them:"
    )
  end

  # One calendar is named in the reason itself; several are listed under it.
  defp list_items([_calendar]), do: []
  defp list_items(calendars), do: calendars
end
