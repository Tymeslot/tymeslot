defmodule Tymeslot.Emails.Templates.PollInvitation do
  @moduledoc """
  Email inviting someone the host added by address to vote on a poll.

  Carries what the host wrote about the poll, the candidate times in the
  invitee's timezone (the poll's when they have none), the deadline, and the
  invitee's personal voting link. Written in the language the invitee was
  given when invited, the host's.
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
    Text
  }

  alias Tymeslot.Locales
  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}
  alias Tymeslot.Utils.DateTimeUtils

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :confirmed

  @doc """
  Renders the invitation. `poll` needs its `time_slots`, its `user` and the
  user's `profile` preloaded.
  """
  @spec render(PollSchema.t(), PollParticipantSchema.t(), String.t()) :: Swoosh.Email.t()
  def render(%PollSchema{} = poll, %PollParticipantSchema{} = participant, voting_url)
      when is_binary(voting_url) do
    locale = Locales.acceptable(participant.locale) || Locales.booking_default_locale()
    host_name = PollHost.display_name(poll)
    timezone = participant.timezone || poll.timezone || "UTC"

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      times = candidate_times(poll, timezone, locale)
      deadline = formatted_deadline(poll, timezone, locale)

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content(poll, host_name, times, deadline, voting_url),
          headline(poll, host_name),
          dgettext("emails_polls", "%{host} is looking for a time for %{title}.",
            host: host_name,
            title: poll.title
          ),
          intent: @intent,
          eyebrow: dgettext("emails_polls", "Poll"),
          stage_title: dgettext("emails_polls", "Help pick a time"),
          stage_subtitle:
            dgettext("emails_polls", "%{host} is looking for a time for %{title}.",
              host: host_name,
              title: poll.title
            )
        )

      MjmlEmail.base_email()
      |> to(PollParticipantSchema.email_recipient(participant))
      |> from({host_name, MjmlEmail.fetch_from_email()})
      |> MjmlEmail.put_reply_to(host_name, PollHost.email(poll))
      |> subject(headline(poll, host_name))
      |> html_body(html_body)
      |> text_body(build_text_body(poll, host_name, times, deadline, voting_url))
    end)
  end

  defp headline(poll, host_name) do
    dgettext("emails_polls", "%{host} invites you to vote on \"%{title}\"",
      host: host_name,
      title: poll.title
    )
  end

  defp intro(host_name) do
    dgettext(
      "emails_polls",
      "%{host} would like to know which of these times suit you. Open your personal link, mark each time, and save.",
      host: host_name
    )
  end

  defp personal_note do
    dgettext(
      "emails_polls",
      "This link is yours alone: anyone who has it can change your responses, so please don't share it. Keep this email to come back later."
    )
  end

  defp mjml_content(poll, host_name, times, deadline, voting_url) do
    """
    #{Text.centered_text(intro(host_name), padding: "4px 0 12px 0")}

    #{note_block(poll.description)}

    #{Text.section_title(dgettext("emails_polls", "Proposed times"))}

    #{Text.bullet_list(times)}

    #{deadline_block(deadline)}

    #{Buttons.action_button(@intent, dgettext("emails_polls", "Vote Now"), voting_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(voting_url)}

    #{Text.system_footer_note(personal_note())}
    """
  end

  defp note_block(description) when is_binary(description) and description != "" do
    """
    #{Text.section_title(dgettext("emails_polls", "Note from the host"))}
    <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="1.6" padding="0 0 8px 0">
      #{Sanitise.sanitize_multiline_for_email(description)}
    </mj-text>
    """
  end

  defp note_block(_description), do: ""

  defp deadline_block(nil), do: ""

  defp deadline_block(deadline) do
    """
    #{Text.section_title(dgettext("emails_polls", "Voting closes"))}
    <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" align="center" padding="0 0 8px 0">
      #{Sanitise.sanitize_for_email(deadline)}
    </mj-text>
    """
  end

  defp build_text_body(poll, host_name, times, deadline, voting_url) do
    """
    #{headline(poll, host_name)}

    #{intro(host_name)}
    #{note_text(poll.description)}
    #{dgettext("emails_polls", "Proposed times")}:
    #{Enum.map_join(times, "\n", &"- #{&1}")}
    #{deadline_text(deadline)}
    #{dgettext("emails_polls", "Vote here:")}
    #{voting_url}

    #{personal_note()}
    """
  end

  defp note_text(description) when is_binary(description) and description != "" do
    "\n#{dgettext("emails_polls", "Note from the host")}:\n#{description}\n"
  end

  defp note_text(_description), do: ""

  defp deadline_text(nil), do: ""

  defp deadline_text(deadline) do
    "\n#{dgettext("emails_polls", "Voting closes:")} #{deadline}\n"
  end

  defp candidate_times(poll, timezone, locale) do
    Enum.map(poll.time_slots, fn slot ->
      slot.start_time
      |> DateTimeUtils.convert_to_timezone(timezone)
      |> Formatting.format_datetime(locale)
    end)
  end

  defp formatted_deadline(%PollSchema{deadline_at: nil}, _timezone, _locale), do: nil

  defp formatted_deadline(%PollSchema{deadline_at: deadline_at}, timezone, locale) do
    deadline_at
    |> DateTimeUtils.convert_to_timezone(timezone)
    |> Formatting.format_datetime(locale)
  end
end
