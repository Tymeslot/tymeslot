defmodule Tymeslot.Emails.Templates.PollDeadlineReminder do
  @moduledoc """
  Email nudging a poll participant to cast their vote before the deadline.

  Sent to a single participant in their own locale, from the poll's host. The
  body carries the poll title, the host's name, the deadline rendered in the
  participant's timezone, and a call-to-action linking to the voting page.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TimezoneHelper
  }

  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

  use Gettext, backend: TymeslotWeb.Gettext

  # A deadline reminder is a time-sensitive prompt to act.
  @intent :alert

  @spec render(PollSchema.t(), PollParticipantSchema.t(), String.t()) :: Swoosh.Email.t()
  def render(%PollSchema{} = poll, %PollParticipantSchema{} = participant, voting_url)
      when is_binary(voting_url) do
    locale = participant.locale || "en"
    host_name = host_display_name(poll)
    deadline = formatted_deadline(poll, participant, locale)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      mjml_content = mjml_content(poll, host_name, deadline, voting_url)

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          dgettext("emails", "Vote on %{title}", title: poll.title),
          dgettext("emails", "%{host} is waiting for your vote on %{title}.",
            host: host_name,
            title: poll.title
          ),
          intent: @intent,
          eyebrow: dgettext("emails", "Reminder"),
          stage_title: dgettext("emails", "Your vote is needed"),
          stage_subtitle:
            dgettext("emails", "Help %{host} lock in a time for %{title}.",
              host: host_name,
              title: poll.title
            )
        )

      MjmlEmail.base_email()
      |> to({participant.name, participant.email})
      |> from({host_name, MjmlEmail.fetch_from_email()})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Reminder: vote on \"%{title}\"", title: poll.title)
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(poll, host_name, deadline, voting_url))
    end)
  end

  defp mjml_content(poll, host_name, deadline, voting_url) do
    """
    #{Text.centered_text(dgettext("emails", "%{host} invited you to help pick a time for %{title}. Your vote is still outstanding.", host: host_name, title: poll.title), padding: "4px 0 12px 0")}

    #{deadline_block(deadline)}

    #{Buttons.action_button(@intent, dgettext("emails", "Cast Your Vote"), voting_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(voting_url)}
    """
  end

  defp deadline_block(nil), do: ""

  defp deadline_block(deadline) do
    """
    #{Text.section_title(dgettext("emails", "Voting closes"))}
    <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" align="center" padding="0 0 8px 0">
      #{Sanitise.sanitize_for_email(deadline)}
    </mj-text>
    """
  end

  defp build_text_body(poll, host_name, deadline, voting_url) do
    """
    #{dgettext("emails", "Reminder: vote on \"%{title}\"", title: poll.title)}

    #{dgettext("emails", "%{host} invited you to help pick a time for %{title}. Your vote is still outstanding.", host: host_name, title: poll.title)}
    #{deadline_text(deadline)}
    #{dgettext("emails", "Cast your vote:")}
    #{voting_url}
    """
  end

  defp deadline_text(nil), do: ""

  defp deadline_text(deadline) do
    "\n#{dgettext("emails", "Voting closes:")} #{deadline}\n"
  end

  defp formatted_deadline(%PollSchema{deadline_at: nil}, _participant, _locale), do: nil

  defp formatted_deadline(%PollSchema{deadline_at: deadline_at}, participant, locale) do
    timezone = participant.timezone || "UTC"

    deadline_at
    |> TimezoneHelper.convert_to_timezone(timezone)
    |> Formatting.format_datetime(locale)
  end

  defp host_display_name(%PollSchema{user: %{profile: %ProfileSchema{} = profile}}) do
    Profiles.display_name(profile) || MjmlEmail.fetch_from_name()
  end

  defp host_display_name(%PollSchema{user: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp host_display_name(_poll), do: MjmlEmail.fetch_from_name()
end
