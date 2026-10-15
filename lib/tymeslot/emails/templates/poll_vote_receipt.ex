defmodule Tymeslot.Emails.Templates.PollVoteReceipt do
  @moduledoc """
  Receipt sent once a participant first saves their responses through their
  voting link, which is what confirms them.

  Lists each candidate time with the participant's answer, in their own
  timezone (the poll's when they have none), and carries the link again so
  they can change their responses until voting closes. Later changes send
  nothing: this email already holds the way back.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MjmlEmail,
    PollHost,
    Sanitise,
    TemplateHelper,
    Text,
    TimezoneHelper
  }

  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :confirmed

  @doc """
  Renders the receipt. `poll` needs its `time_slots`, its `user` and the
  user's `profile` preloaded; `participant` needs its `votes`.
  """
  @spec render(PollSchema.t(), PollParticipantSchema.t(), String.t()) :: Swoosh.Email.t()
  def render(%PollSchema{} = poll, %PollParticipantSchema{} = participant, voting_url)
      when is_binary(voting_url) do
    locale = participant.locale || "en"
    host_name = PollHost.display_name(poll)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      responses = response_lines(poll, participant, locale)

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content(poll, responses, voting_url),
          dgettext("emails_polls", "Your responses to %{title}", title: poll.title),
          dgettext("emails_polls", "Your responses to %{title} count now.", title: poll.title),
          intent: @intent,
          eyebrow: dgettext("emails_polls", "Poll"),
          stage_title: dgettext("emails_polls", "Thanks for voting"),
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
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_polls", "Your responses to \"%{title}\"", title: poll.title)
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(poll, responses, voting_url))
    end)
  end

  defp mjml_content(poll, responses, voting_url) do
    """
    #{Text.centered_text(intro(poll), padding: "4px 0 12px 0")}

    #{Text.section_title(dgettext("emails_polls", "Your responses"))}

    #{Text.bullet_list(responses)}

    #{Buttons.action_button(@intent, dgettext("emails_polls", "Change My Responses"), voting_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(voting_url)}

    #{Text.system_footer_note(personal_note())}
    """
  end

  defp intro(poll) do
    dgettext(
      "emails_polls",
      "Your email address is confirmed and your responses to %{title} count now. You can change them with the link below until voting closes.",
      title: poll.title
    )
  end

  defp personal_note do
    dgettext(
      "emails_polls",
      "This link is yours alone: anyone who has it can change your responses, so please don't share it."
    )
  end

  defp build_text_body(poll, responses, voting_url) do
    """
    #{dgettext("emails_polls", "Your responses to \"%{title}\"", title: poll.title)}

    #{intro(poll)}

    #{dgettext("emails_polls", "Your responses")}:
    #{Enum.map_join(responses, "\n", &"- #{&1}")}

    #{dgettext("emails_polls", "Change your responses:")}
    #{voting_url}

    #{personal_note()}
    """
  end

  defp response_lines(poll, participant, locale) do
    timezone = participant.timezone || poll.timezone || "UTC"
    responses = Map.new(participant.votes, &{&1.poll_time_slot_id, &1.response})

    Enum.map(poll.time_slots, fn slot ->
      time =
        slot.start_time
        |> TimezoneHelper.convert_to_timezone(timezone)
        |> Formatting.format_datetime(locale)

      "#{time}: #{response_label(Map.get(responses, slot.id))}"
    end)
  end

  defp response_label(:yes), do: dgettext("emails_polls", "Yes")
  defp response_label(:if_need_be), do: dgettext("emails_polls", "If need be")
  defp response_label(:no), do: dgettext("emails_polls", "No")
  defp response_label(nil), do: dgettext("emails_polls", "No answer")
end
