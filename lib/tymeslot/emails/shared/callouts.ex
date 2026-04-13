defmodule Tymeslot.Emails.Shared.Callouts do
  @moduledoc """
  Tinted, intent-coloured callout blocks for Tymeslot emails — 2026 redesign.

  A callout is a semantic block that draws the eye: a left colour rail, a
  tinted surface, and bold ink that shares the intent's accent colour. Use
  these for alerts, warnings, and preparation reminders where the message
  needs to stand apart from body copy.
  """

  alias Tymeslot.Emails.Shared.Sanitise
  alias Tymeslot.Emails.Shared.Styles
  alias Tymeslot.Emails.Shared.Styles.Tokens

  @doc """
  A semantic alert box — left colour rail, bold title, body copy, tinted
  surface matching the supplied intent.

  `intent` is an intent atom from `Tymeslot.Emails.Shared.Styles.Tokens`. No string
  vocabulary, no default: the caller declares the intent.

  Options:
  - `:title` — optional bold title
  - `:icon` — optional emoji/icon prefix for the title
  """
  @spec alert_box(Tokens.intent(), String.t(), keyword()) :: String.t()
  def alert_box(intent, message, opts \\ []) when is_atom(intent) do
    title = Keyword.get(opts, :title)
    icon = Keyword.get(opts, :icon)

    safe_message = Sanitise.sanitize_for_email(message)
    safe_title = if title, do: Sanitise.sanitize_for_email(title)
    safe_icon = if icon, do: Sanitise.sanitize_for_email(icon)

    tokens = Styles.intent(intent)

    title_block =
      if safe_title do
        icon_prefix = if safe_icon, do: "#{safe_icon} ", else: ""

        """
        <mj-text
          font-size="15px"
          font-weight="700"
          color="#{tokens.accent_ink}"
          padding="0 0 4px 0"
          line-height="1.3"
        >
          #{icon_prefix}#{safe_title}
        </mj-text>
        """
      else
        ""
      end

    """
    <mj-section
      padding="16px 18px"
      background-color="#{tokens.tint}"
      border-left="4px solid #{tokens.accent}"
      border-radius="#{Styles.radius(:md)}"
      css-class="mobile-card"
    >
      <mj-column>
        #{title_block}
        <mj-text
          font-size="14px"
          color="#{tokens.accent_ink}"
          line-height="1.5"
          padding="0"
        >
          #{safe_message}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A preparation checklist — tinted card with a bold title and hairline-divided
  items, each prefixed with a coloured status dot.

  `intent` is an intent atom from `Tymeslot.Emails.Shared.Styles.Tokens`.

  Options:
  - `:title` — the card title (default: `"Checklist"`)
  """
  @spec preparation_checklist(Tokens.intent(), list(String.t()), keyword()) :: String.t()
  def preparation_checklist(intent, items, opts \\ [])

  def preparation_checklist(intent, [_head | _tail] = items, opts) when is_atom(intent) do
    title = Keyword.get(opts, :title, "Checklist")
    tokens = Styles.intent(intent)

    rows =
      items
      |> Enum.map(&Sanitise.sanitize_for_email/1)
      |> Enum.map_join("\n", fn item ->
        """
        <mj-text
          font-size="14px"
          color="#{tokens.accent_ink}"
          line-height="1.55"
          padding="8px 0"
        >
          <span style="display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #{tokens.accent}; margin-right: 10px; vertical-align: middle;"></span>#{item}
        </mj-text>
        """
      end)

    """
    <mj-section
      padding="18px 20px"
      background-color="#{tokens.tint}"
      border-radius="#{Styles.radius(:md)}"
      css-class="mobile-card"
    >
      <mj-column>
        <mj-text
          font-size="12px"
          font-weight="700"
          color="#{tokens.accent_ink}"
          letter-spacing="0.12em"
          text-transform="uppercase"
          padding="0 0 10px 0"
        >
          #{Sanitise.sanitize_for_email(title)}
        </mj-text>
        #{rows}
      </mj-column>
    </mj-section>
    """
  end

  def preparation_checklist(intent, _items, _opts) when is_atom(intent), do: ""
end
