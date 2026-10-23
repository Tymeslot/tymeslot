defmodule Tymeslot.Emails.Templates.PollVoteDigest do
  @moduledoc """
  The host's update on new votes, for a poll with `notify_on_vote` on.

  Bundles everyone who voted or changed their responses since the last update
  (at most one every quarter hour, see
  `Tymeslot.Emails.EmailScheduler.PollScheduler.schedule_vote_digest/1`),
  with the poll's current standings. The poll needs its `time_slots` and its
  `participants` with their `votes` preloaded.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Buttons,
    MjmlEmail,
    PollHost,
    PollStandings,
    TemplateHelper,
    Text
  }

  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :confirmed

  @spec render(PollSchema.t(), [PollParticipantSchema.t()], String.t()) :: Swoosh.Email.t()
  def render(%PollSchema{} = poll, [_first | _rest] = voters, results_url)
      when is_binary(results_url) do
    locale = RecipientLocale.locale_for(poll.user)
    host_name = PollHost.display_name(poll)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      headline = headline(poll, voters)
      names = Enum.map_join(voters, ", ", &PollParticipantSchema.display_name/1)

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content(names, PollStandings.mjml(poll, locale), results_url),
          headline,
          headline,
          intent: @intent,
          eyebrow: dgettext("emails_polls", "New responses"),
          stage_title: headline,
          stage_subtitle: poll.title
        )

      MjmlEmail.base_email(tracking: :lifecycle)
      |> to({host_name, poll.user.email})
      |> subject(dgettext("emails_polls", "New responses on \"%{title}\"", title: poll.title))
      |> html_body(html_body)
      |> text_body(
        build_text_body(headline, names, PollStandings.text(poll, locale), results_url)
      )
    end)
  end

  defp headline(poll, voters) do
    dngettext(
      "emails_polls",
      "%{count} new response on %{title}",
      "%{count} new responses on %{title}",
      length(voters),
      title: poll.title
    )
  end

  defp from_line(names),
    do: dgettext("emails_polls", "Responses from: %{names}", names: names)

  defp settings_note do
    dgettext(
      "emails_polls",
      "You get these updates, at most one every 15 minutes, because they are on for this poll. You can turn them off when you edit the poll."
    )
  end

  defp mjml_content(names, standings, results_url) do
    """
    #{Text.centered_text(from_line(names), padding: "4px 0 12px 0")}

    #{standings}

    #{Buttons.action_button(@intent, dgettext("emails_polls", "View Results"), results_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(results_url)}

    #{Text.system_footer_note(settings_note())}
    """
  end

  defp build_text_body(headline, names, standings, results_url) do
    """
    #{headline}

    #{from_line(names)}

    #{standings}
    #{dgettext("emails_polls", "View the results:")}
    #{results_url}

    #{settings_note()}
    """
  end
end
