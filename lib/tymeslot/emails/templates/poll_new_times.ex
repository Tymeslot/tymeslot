defmodule Tymeslot.Emails.Templates.PollNewTimes do
  @moduledoc """
  Email telling a participant who has already voted that the host added
  candidate times, so they can answer those too.

  Lists only the new times, in the participant's timezone (the poll's when
  they have none), and carries their personal voting link. The poll needs its
  `user` and the user's `profile` preloaded.
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

  @spec render(PollSchema.t(), PollParticipantSchema.t(), [map()], String.t()) ::
          Swoosh.Email.t()
  def render(%PollSchema{} = poll, %PollParticipantSchema{} = participant, slots, voting_url)
      when is_binary(voting_url) do
    locale = participant.locale || "en"
    host_name = PollHost.display_name(poll)
    timezone = participant.timezone || poll.timezone || "UTC"

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      times = Enum.map(slots, &format_time(&1, timezone, locale))
      headline = dgettext("emails_polls", "New times for %{title}", title: poll.title)

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content(host_name, times, voting_url),
          headline,
          intro(host_name),
          intent: @intent,
          eyebrow: dgettext("emails_polls", "Poll"),
          stage_title: headline,
          stage_subtitle: intro(host_name)
        )

      MjmlEmail.base_email()
      |> to(PollParticipantSchema.email_recipient(participant))
      |> from({host_name, MjmlEmail.fetch_from_email()})
      |> MjmlEmail.put_reply_to(host_name, PollHost.email(poll))
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_polls", "New times to vote on in \"%{title}\"", title: poll.title)
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(headline, host_name, times, voting_url))
    end)
  end

  defp intro(host_name) do
    dgettext(
      "emails_polls",
      "%{host} added times to the poll. Your earlier responses are kept; please answer the new times too.",
      host: host_name
    )
  end

  defp mjml_content(host_name, times, voting_url) do
    """
    #{Text.centered_text(intro(host_name), padding: "4px 0 12px 0")}

    #{Text.section_title(dgettext("emails_polls", "New times"))}

    #{Text.bullet_list(times)}

    #{Buttons.action_button(@intent, dgettext("emails_polls", "Answer the New Times"), voting_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(voting_url)}
    """
  end

  defp build_text_body(headline, host_name, times, voting_url) do
    """
    #{headline}

    #{intro(host_name)}

    #{dgettext("emails_polls", "New times")}:
    #{Enum.map_join(times, "\n", &"- #{&1}")}

    #{dgettext("emails_polls", "Vote here:")}
    #{voting_url}
    """
  end

  defp format_time(slot, timezone, locale) do
    slot.start_time
    |> TimezoneHelper.convert_to_timezone(timezone)
    |> Formatting.format_datetime(locale)
  end
end
