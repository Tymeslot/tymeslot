defmodule Tymeslot.Emails.Shared.Meeting.ActionsBar do
  @moduledoc """
  The reschedule / cancel action row for meeting emails.

  Rendered as a compact row of text links separated by a middle dot so the
  primary CTA (e.g. the join button) stays visually dominant. Each action's
  colour is determined by its `:style` and the surrounding email intent.
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles, Text}
  alias Tymeslot.Emails.Shared.Styles.Tokens

  @type button_spec :: %{
          required(:text) => String.t(),
          required(:url) => String.t() | nil,
          optional(:style) => atom(),
          optional(:opts) => keyword()
        }

  @doc """
  The actions that can be offered: those whose URL is present and safe to
  link (`Sanitise.safe_url?/1`). An action without one is left out rather
  than linked to nowhere.
  """
  @spec available(list(button_spec())) :: list(button_spec())
  def available(actions), do: Enum.filter(actions, &Sanitise.safe_url?(&1.url))

  @doc """
  Renders the actions bar for the supplied intent. Link colour per action:
  `:primary` inherits the email intent's deep accent, `:danger` uses the
  cancelled intent (always rose), `:secondary` uses muted ink.

  Only the `available/1` actions are rendered; with none, the bar renders
  nothing.
  """
  @spec meeting_actions_bar(Tokens.intent(), list(button_spec())) :: String.t()
  def meeting_actions_bar(intent, actions) when is_atom(intent) and is_list(actions) do
    case available(actions) do
      [] -> ""
      offered -> bar(intent, offered)
    end
  end

  @doc """
  The actions bar under a section title, or nothing at all when no action is
  available: a heading such as "Need to make changes?" over an empty row
  would promise actions the email does not offer.

  Options: `:footer`, a note rendered under the bar, and only with it.
  """
  @spec actions_section(Tokens.intent(), String.t(), list(button_spec()), keyword()) ::
          String.t()
  def actions_section(intent, title, actions, opts \\ []) when is_atom(intent) do
    case available(actions) do
      [] ->
        ""

      offered ->
        """
        #{Text.section_title(title)}

        #{bar(intent, offered)}

        #{footer(Keyword.get(opts, :footer))}
        """
    end
  end

  defp footer(nil), do: ""

  defp footer(note),
    do: Text.centered_text(note, font_size: "14px", padding: "16px 0 0 0")

  defp bar(intent, actions) do
    separator = ~s(<span style="color: #{Styles.ink_whisper()}; padding: 0 12px;">·</span>)

    links =
      Enum.map_join(actions, separator, fn action ->
        safe_text = Sanitise.sanitize_for_email(action.text)
        safe_url = Sanitise.sanitize_url(action.url)
        color = action_link_color(intent, Map.get(action, :style, :primary))

        ~s(<a href="#{safe_url}" style="color: #{color}; text-decoration: none; font-weight: 600; border-bottom: 1px solid #{Styles.hairline()}; padding-bottom: 1px;">#{safe_text}</a>)
      end)

    """
    <mj-section padding="14px 0 4px 0">
      <mj-column>
        <mj-text
          align="center"
          font-size="14px"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.02em"
        >
          #{links}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @spec action_link_color(Tokens.intent(), :primary | :secondary | :danger | atom()) ::
          String.t()
  defp action_link_color(_intent, :danger), do: Styles.intent_accent_deep(:cancelled)
  defp action_link_color(_intent, :secondary), do: Styles.ink_muted()
  defp action_link_color(intent, :primary), do: Styles.intent_accent_deep(intent)
  defp action_link_color(_intent, _other), do: Styles.ink_muted()
end
