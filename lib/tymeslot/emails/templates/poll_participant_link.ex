defmodule Tymeslot.Emails.Templates.PollParticipantLink do
  @moduledoc """
  Email carrying a participant's personal voting link, sent when they ask for
  it on the voting page.

  The link is the only way to vote, so receiving it proves the address. Anyone
  can type any address into that form, so the email names no one but the host:
  not even the name the requester typed, which would otherwise put a stranger's
  words into someone else's inbox. It says plainly that ignoring it is safe.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MjmlEmail,
    PollHost,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TimezoneHelper
  }

  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :confirmed

  @spec render(PollSchema.t(), PollParticipantSchema.t(), String.t()) :: Swoosh.Email.t()
  def render(%PollSchema{} = poll, %PollParticipantSchema{} = participant, voting_url)
      when is_binary(voting_url) do
    locale = participant.locale || "en"
    host_name = PollHost.display_name(poll)
    deadline = formatted_deadline(poll, participant, locale)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      html_body =
        TemplateHelper.compile_system_template(
          mjml_content(poll, host_name, deadline, voting_url),
          dgettext("emails_polls", "Your link to vote on %{title}", title: poll.title),
          dgettext("emails_polls", "%{host} is looking for a time for %{title}.",
            host: host_name,
            title: poll.title
          ),
          intent: @intent,
          eyebrow: dgettext("emails_polls", "Poll"),
          stage_title: dgettext("emails_polls", "Your voting link"),
          stage_subtitle:
            dgettext("emails_polls", "%{host} is looking for a time for %{title}.",
              host: host_name,
              title: poll.title
            )
        )

      MjmlEmail.base_email()
      |> to(participant.email)
      |> from({host_name, MjmlEmail.fetch_from_email()})
      |> MjmlEmail.put_reply_to(host_name, PollHost.email(poll))
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_polls", "Your link to vote on \"%{title}\"", title: poll.title)
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(poll, host_name, deadline, voting_url))
    end)
  end

  defp mjml_content(poll, host_name, deadline, voting_url) do
    """
    #{Text.centered_text(intro(poll, host_name), padding: "4px 0 12px 0")}

    #{deadline_block(deadline)}

    #{Buttons.action_button(@intent, dgettext("emails_polls", "Vote Now"), voting_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(voting_url)}

    #{Text.system_footer_note(personal_note())}

    #{Text.system_footer_note(ignore_note())}
    """
  end

  defp intro(poll, host_name) do
    dgettext(
      "emails_polls",
      "Here is your link to vote on %{title} for %{host}. Your responses count once you save them through it.",
      title: poll.title,
      host: host_name
    )
  end

  defp personal_note do
    dgettext(
      "emails_polls",
      "This link is yours alone: anyone who has it can change your responses, so please don't share it. Keep this email to come back later."
    )
  end

  defp ignore_note do
    dgettext(
      "emails_polls",
      "Didn't ask for this? Then you can ignore this email. Nothing is recorded unless the link is used."
    )
  end

  defp deadline_block(nil), do: ""

  defp deadline_block(deadline) do
    """
    #{Text.section_title(dgettext("emails_polls", "Voting closes"))}
    <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" align="center" padding="0 0 8px 0">
      #{Sanitise.sanitize_for_email(deadline)}
    </mj-text>
    """
  end

  defp build_text_body(poll, host_name, deadline, voting_url) do
    """
    #{dgettext("emails_polls", "Your link to vote on \"%{title}\"", title: poll.title)}

    #{intro(poll, host_name)}
    #{deadline_text(deadline)}
    #{dgettext("emails_polls", "Vote here:")}
    #{voting_url}

    #{personal_note()}

    #{ignore_note()}
    """
  end

  defp deadline_text(nil), do: ""

  defp deadline_text(deadline) do
    "\n#{dgettext("emails_polls", "Voting closes:")} #{deadline}\n"
  end

  defp formatted_deadline(%PollSchema{deadline_at: nil}, _participant, _locale), do: nil

  defp formatted_deadline(%PollSchema{deadline_at: deadline_at} = poll, participant, locale) do
    deadline_at
    |> TimezoneHelper.convert_to_timezone(participant.timezone || poll.timezone || "UTC")
    |> Formatting.format_datetime(locale)
  end
end
