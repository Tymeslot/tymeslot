defmodule Tymeslot.Emails.Shared.IntegrationNotice do
  @moduledoc """
  The one layout every integration notice to an owner shares: a callout with
  the reason, "What's happening?", what to do about it, a button to the
  integration's settings, and a footer saying when the owner hears again.

  A template describes its notice as a `t:copy/0` in the recipient's locale;
  `email/2` builds the addressed email with both parts from that one copy, so
  the HTML and the plain text cannot say different things.

  A piece of prose is either a string or `{sentence, emphasis}`, where
  `emphasis` is a substring of `sentence` set in bold in the HTML part. The
  sentence is translated whole, so a translator never sees it in pieces.
  """

  alias Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Callouts,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text
  }

  @intent :alert

  @type prose :: String.t() | {String.t(), String.t()}

  @typedoc """
  * `:subject`: the subject line
  * `:title`: the callout's and the stage's title, and the plain text's first line
  * `:preheader`: the inbox preview text
  * `:subtitle`: the stage's subtitle
  * `:reason`: the callout's message, with optional `:reason_items` listed under it
  * `:happening`: the "What's happening?" paragraph
  * `:next_heading`: the heading of the next section
  * `:next`: what to do, as one paragraph or a list of steps
  * `:button` and `:settings_url`: the call to action
  * `:footer`: when the owner hears about this again
  """
  @type copy :: %{
          required(:subject) => String.t(),
          required(:title) => String.t(),
          required(:preheader) => String.t(),
          required(:subtitle) => String.t(),
          required(:eyebrow) => String.t(),
          required(:reason) => String.t(),
          optional(:reason_items) => [String.t()],
          required(:happening_heading) => String.t(),
          required(:happening) => prose(),
          required(:next_heading) => String.t(),
          required(:next) => prose() | [prose()],
          required(:button) => String.t(),
          required(:settings_url) => String.t(),
          required(:footer) => String.t()
        }

  @doc "The notice as an email to `user`, built from `copy`."
  @spec email(%{required(:email) => String.t(), optional(atom()) => term()}, copy()) ::
          Email.t()
  def email(user, copy) do
    MjmlEmail.base_email()
    |> Email.to({Map.get(user, :name) || user.email, user.email})
    |> Email.subject(copy.subject)
    |> Email.html_body(html(copy))
    |> Email.text_body(text(copy))
  end

  defp html(copy) do
    mjml_content = """
    #{Callouts.alert_box(:alert, copy.reason, title: copy.title, items: Map.get(copy, :reason_items, []))}

    #{Text.title_section(copy.happening_heading)}

    <mj-text
      font-size="16px"
      color="#{Styles.ink_soft()}"
      line-height="1.5"
      align="left"
      css-class="mobile-text"
    >
      #{prose_html(copy.happening)}
    </mj-text>

    #{Text.divider()}

    #{Text.title_section(copy.next_heading)}

    <mj-text color="#{Styles.ink_soft()}" font-size="14px" line-height="1.6">
      #{next_html(copy.next)}
    </mj-text>

    #{Buttons.action_button(@intent, copy.button, copy.settings_url)}

    #{Text.divider()}

    #{Text.system_footer_note(copy.footer)}
    """

    TemplateHelper.compile_system_template(mjml_content, copy.title, copy.preheader,
      intent: @intent,
      eyebrow: copy.eyebrow,
      stage_title: copy.title,
      stage_subtitle: copy.subtitle
    )
  end

  defp text(copy) do
    """
    #{copy.title}

    #{copy.reason}#{Enum.map_join(Map.get(copy, :reason_items, []), "", &("\n- " <> &1))}

    #{String.upcase(copy.happening_heading)}
    #{prose_text(copy.happening)}

    #{String.upcase(copy.next_heading)}
    #{next_text(copy.next)}

    #{copy.button}:
    #{copy.settings_url}

    #{copy.footer}
    """
  end

  defp next_html(steps) when is_list(steps) do
    last = length(steps) - 1

    items =
      steps
      |> Enum.with_index()
      |> Enum.map_join("\n        ", fn {step, index} ->
        margin = if index == last, do: "0", else: "8px"
        ~s(<li style="margin-bottom: #{margin};">#{prose_html(step)}</li>)
      end)

    """
    <ul style="padding-left: 20px; margin: 0;">
        #{items}
      </ul>
    """
  end

  defp next_html(paragraph), do: prose_html(paragraph)

  defp next_text(steps) when is_list(steps),
    do: Enum.map_join(steps, "\n", &("- " <> prose_text(&1)))

  defp next_text(paragraph), do: prose_text(paragraph)

  # An empty emphasis has nothing to set in bold, and String.replace/4 would
  # put an empty tag in front of the sentence.
  defp prose_html({sentence, ""}), do: prose_html(sentence)

  defp prose_html({sentence, emphasis}) do
    safe_emphasis = Sanitise.sanitize_for_email(emphasis)

    sentence
    |> Sanitise.sanitize_for_email()
    |> String.replace(safe_emphasis, "<strong>#{safe_emphasis}</strong>", global: false)
  end

  defp prose_html(sentence), do: Sanitise.sanitize_for_email(sentence)

  defp prose_text({sentence, _emphasis}), do: sentence
  defp prose_text(sentence), do: sentence
end
