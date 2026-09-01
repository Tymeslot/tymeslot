defmodule Tymeslot.Emails.Templates.PollHostNudge do
  @moduledoc """
  Email nudging the poll host to pick a final time from the results.

  Two variants drive the copy:

    * `:all_voted`: every participant has voted, so the host can decide now.
    * `:deadline_passed`: voting has closed and it is time to decide.

  Sent to the host in the instance's default locale, mirroring how the other
  organiser-facing templates resolve the sender's language.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{Buttons, MjmlEmail, Sanitise, TemplateHelper, Text}
  alias Tymeslot.Locales
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

  use Gettext, backend: TymeslotWeb.Gettext

  @type variant :: :all_voted | :deadline_passed

  @spec render(PollSchema.t(), variant(), String.t()) :: Swoosh.Email.t()
  def render(%PollSchema{} = poll, variant, results_url)
      when variant in [:all_voted, :deadline_passed] and is_binary(results_url) do
    locale = Locales.admin_default_locale()
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
            dgettext("emails", "Pick a final time so everyone can put it in the diary.")
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

    #{Buttons.action_button(copy.intent, dgettext("emails", "Pick a Time"), results_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(results_url)}
    """
  end

  defp build_text_body(copy, results_url) do
    """
    #{copy.headline}

    #{copy.body}

    #{dgettext("emails", "Pick a time:")}
    #{results_url}
    """
  end

  defp copy(:all_voted, title) do
    %{
      intent: :confirmed,
      eyebrow: dgettext("emails", "All votes in"),
      subject:
        dgettext("emails", "Everyone has voted on \"%{title}\", pick a time", title: title),
      headline: dgettext("emails", "Everyone has voted on %{title}", title: title),
      body:
        dgettext(
          "emails",
          "Every participant has cast their vote on %{title}. Review the results and confirm the time that works best.",
          title: title
        )
    }
  end

  defp copy(:deadline_passed, title) do
    %{
      intent: :alert,
      eyebrow: dgettext("emails", "Voting closed"),
      subject: dgettext("emails", "Voting has closed on \"%{title}\", pick a time", title: title),
      headline: dgettext("emails", "Voting has closed on %{title}", title: title),
      body:
        dgettext(
          "emails",
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
end
