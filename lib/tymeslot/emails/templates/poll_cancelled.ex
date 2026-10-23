defmodule Tymeslot.Emails.Templates.PollCancelled do
  @moduledoc """
  Email telling a participant that the host cancelled a poll, so no meeting
  will come of it. Sent in the participant's language, from the host, with
  replies going to them; it invites a reply, naming the host, only when a
  reply does reach them (`MjmlEmail.replies_reach?/1`). The poll needs its
  `user` and the user's `profile` preloaded.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{MjmlEmail, PollHost, TemplateHelper, Text}
  alias Tymeslot.Locales
  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  @spec render(PollSchema.t(), PollParticipantSchema.t()) :: Swoosh.Email.t()
  def render(%PollSchema{} = poll, %PollParticipantSchema{} = participant) do
    locale = Locales.acceptable(participant.locale) || Locales.booking_default_locale()
    host_name = PollHost.display_name(poll)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      headline = dgettext("emails_polls", "%{title} has been cancelled", title: poll.title)
      body = Enum.join([body(poll, host_name) | reply_note(poll, host_name)], " ")

      html_body =
        TemplateHelper.compile_system_template(
          Text.centered_text(body, padding: "4px 0 12px 0"),
          headline,
          body,
          intent: @intent,
          eyebrow: dgettext("emails_polls", "Poll cancelled"),
          stage_title: headline,
          stage_subtitle: dgettext("emails_polls", "No time will be picked.")
        )

      MjmlEmail.base_email()
      |> to(PollParticipantSchema.email_recipient(participant))
      |> from({host_name, MjmlEmail.fetch_from_email()})
      |> MjmlEmail.put_reply_to(host_name, PollHost.email(poll))
      |> subject(dgettext("emails_polls", "Poll cancelled: \"%{title}\"", title: poll.title))
      |> html_body(html_body)
      |> text_body("#{headline}\n\n#{body}\n")
    end)
  end

  defp body(poll, host_name) do
    dgettext(
      "emails_polls",
      "%{host} has cancelled the poll %{title}, so no meeting will be scheduled from it. Thank you for your responses.",
      host: host_name,
      title: poll.title
    )
  end

  # Only when `Reply-To` is set: otherwise a reply would go to the sending
  # mailbox, not to the host.
  defp reply_note(poll, host_name) do
    if MjmlEmail.replies_reach?(PollHost.email(poll)) do
      [
        dgettext(
          "emails_polls",
          "If you have questions, just reply to this email; your reply goes straight to %{host}.",
          host: host_name
        )
      ]
    else
      []
    end
  end
end
