defmodule Tymeslot.Emails.Templates.PollHostNudge do
  @moduledoc """
  Email nudging the poll host to pick a final time from the results.

  Two variants drive the copy:

    * `:all_voted`: every participant has voted, so the host can decide now.
    * `:deadline_passed`: voting has closed and it is time to decide.

  Sent to the host in their own language (`users.locale`), falling back to the
  default locale like the other organiser-facing templates.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{Buttons, MjmlEmail, Sanitise, TemplateHelper, Text}
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

  use Gettext, backend: TymeslotWeb.Gettext

  @type variant :: :all_voted | :deadline_passed

  @spec render(PollSchema.t(), variant(), String.t()) :: Swoosh.Email.t()
  def render(%PollSchema{} = poll, variant, results_url)
      when variant in [:all_voted, :deadline_passed] and is_binary(results_url) do
    locale = host_locale(poll)
    host_name = host_display_name(poll)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      copy = copy(variant, poll.title)
      mjml_content = mjml_content(copy, results_url)

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          copy.headline,
          copy.headline,
          intent: copy.intent,
          eyebrow: copy.eyebrow,
          stage_title: copy.headline,
          stage_subtitle:
            dgettext("emails_polls", "Pick a final time so everyone can put it in the diary.")
        )

      MjmlEmail.base_email(tracking: :lifecycle)
      |> to({host_name, poll.user.email})
      |> subject(Sanitise.sanitize_for_header(copy.subject))
      |> html_body(html_body)
      |> text_body(build_text_body(copy, results_url))
    end)
  end

  defp mjml_content(copy, results_url) do
    """
    #{Text.centered_text(copy.body, padding: "4px 0 12px 0")}

    #{Buttons.action_button(copy.intent, dgettext("emails_polls", "Pick a Time"), results_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(results_url)}
    """
  end

  defp build_text_body(copy, results_url) do
    """
    #{copy.headline}

    #{copy.body}

    #{dgettext("emails_polls", "Pick a time:")}
    #{results_url}
    """
  end

  defp copy(:all_voted, title) do
    %{
      intent: :confirmed,
      eyebrow: dgettext("emails_polls", "All votes in"),
      subject:
        dgettext("emails_polls", "Everyone has voted on \"%{title}\", pick a time", title: title),
      headline: dgettext("emails_polls", "Everyone has voted on %{title}", title: title),
      body:
        dgettext(
          "emails_polls",
          "Every participant has cast their vote on %{title}. Review the results and confirm the time that works best.",
          title: title
        )
    }
  end

  defp copy(:deadline_passed, title) do
    %{
      intent: :alert,
      eyebrow: dgettext("emails_polls", "Voting closed"),
      subject:
        dgettext("emails_polls", "Voting has closed on \"%{title}\", pick a time", title: title),
      headline: dgettext("emails_polls", "Voting has closed on %{title}", title: title),
      body:
        dgettext(
          "emails_polls",
          "The deadline for %{title} has passed. Review the results and confirm the time that works best.",
          title: title
        )
    }
  end

  defp host_display_name(%PollSchema{user: %{profile: %ProfileSchema{} = profile}}) do
    Profiles.display_name(profile) || MjmlEmail.fetch_from_name()
  end

  defp host_display_name(%PollSchema{user: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp host_display_name(_poll), do: MjmlEmail.fetch_from_name()

  defp host_locale(%PollSchema{user: %{locale: _locale} = user}),
    do: RecipientLocale.locale_for(user)

  defp host_locale(%PollSchema{user_id: user_id}), do: RecipientLocale.locale_for_user_id(user_id)
end
