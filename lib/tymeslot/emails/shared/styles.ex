defmodule Tymeslot.Emails.Shared.Styles do
  @moduledoc """
  Public facade for the Tymeslot email design system — 2026 redesign.

  The system is split across three focused sub-modules:

  - `Tymeslot.Emails.Shared.Styles.Tokens` — design-token data and lookups
    (palette, intents, typography, radius).
  - `Tymeslot.Emails.Shared.Styles.BrandPalette` — derives the `:confirmed`
    brand colour family from a configured accent, for `Tokens` to consume.
  - `Tymeslot.Emails.Shared.Styles.CSS` — MJML attribute defaults and the
    embedded CSS stylesheet, including mobile and dark-mode variants.

  This module re-exports the common public API plus a small set of
  legacy-vocabulary helpers used by `Buttons`, `Cards`, `MeetingComponents`,
  and `event_update_notification` (old-name button and table helpers kept as
  thin wrappers over the token system).

  ## Redesign notes

  The palette is **inversion-survivable**: no pure whites, no near-blacks.
  Every base value is chosen so that a client-forced colour inversion (as
  performed by Thunderbird and some mobile clients) still produces a coherent,
  warm result. There is no separate dark-mode stylesheet — the single palette
  carries both light and inverted clients coherently.

  ## Intents

  An intent is a semantic category describing the purpose of an email. There
  are exactly three:

  - `:confirmed` — the brand accent (turquoise by default; a self-hosted
    instance can configure its own). The default for every informational,
    welcome, reminder, invitation, trial, subscription, or confirmation email.
  - `:alert` — amber. The "attention needed" signal.
  - `:cancelled` — rose. The "something is wrong" signal.

  Templates declare their intent explicitly; there is no inference or default.
  """

  alias Tymeslot.Emails.Shared.Styles.{CSS, Tokens}
  alias Tymeslot.Utils.Colour

  # ============================================================================
  # TOKEN FACADE — delegates to Styles.Tokens
  # ============================================================================

  defdelegate canvas, to: Tokens
  defdelegate canvas_soft, to: Tokens
  defdelegate surface, to: Tokens
  defdelegate hairline, to: Tokens
  defdelegate ink, to: Tokens
  defdelegate ink_soft, to: Tokens
  defdelegate ink_muted, to: Tokens
  defdelegate ink_whisper, to: Tokens
  defdelegate font_size(key), to: Tokens
  defdelegate radius(key), to: Tokens
  defdelegate intent(intent_key), to: Tokens
  defdelegate intent_accent(intent_key), to: Tokens
  defdelegate intent_accent_deep(intent_key), to: Tokens

  # ============================================================================
  # CSS FACADE — delegates to Styles.CSS
  # ============================================================================

  defdelegate mjml_base_attributes, to: CSS
  defdelegate email_css_styles, to: CSS

  # ============================================================================
  # LEGACY VOCABULARY — old-name helpers that remain the live public API for
  # Buttons, Cards, MeetingComponents, and event_update_notification. Kept as
  # thin wrappers over tokens so these call sites don't need to be rewritten.
  # These are not shims — they are the stable API; do not delete them.
  # ============================================================================

  @doc "Text colour by semantic role (legacy vocabulary)."
  @spec text_color(:primary | :secondary | :muted | :dark | :subtle) :: String.t()
  def text_color(:primary), do: Tokens.ink()
  def text_color(:secondary), do: Tokens.ink_soft()
  def text_color(:muted), do: Tokens.ink_muted()
  def text_color(:dark), do: Tokens.ink_soft()
  def text_color(:subtle), do: Tokens.ink_whisper()

  @doc "Border colour by semantic role (legacy vocabulary)."
  @spec border_color(:default | :subtle) :: String.t()
  def border_color(:subtle), do: Tokens.hairline_soft()
  def border_color(_other), do: Tokens.hairline()

  @doc """
  Button text colour for the given background, chosen for contrast rather
  than assumed. Intent accents range from pale (a light custom brand colour)
  to dark, so a single fixed text colour cannot serve all of them — this
  picks whichever of the palette's near-white surface token and dark ink
  token clears more contrast against `background_hex`.
  """
  @spec button_text_color(String.t()) :: String.t()
  def button_text_color(background_hex) do
    light = Tokens.surface()
    dark = Tokens.ink()

    if Colour.contrast_ratio(background_hex, dark) >= Colour.contrast_ratio(background_hex, light) do
      dark
    else
      light
    end
  end

  @doc "Button padding by size."
  @spec button_padding(atom()) :: String.t()
  def button_padding(:large), do: "18px 32px"
  def button_padding(:small), do: "10px 18px"
  def button_padding(_medium), do: "14px 26px"

  @doc "Legacy pill radius used by buttons."
  @spec button_radius() :: String.t()
  def button_radius, do: Tokens.radius(:pill)

  @doc "Legacy card radius."
  @spec card_radius() :: String.t()
  def card_radius, do: Tokens.radius(:lg)

  @doc "Legacy turquoise link colour, used by section links in `MeetingComponents` and similar."
  @spec component_color(:link) :: String.t()
  def component_color(:link), do: Tokens.intent_accent_deep(:confirmed)

  @doc "Legacy `<table>` wrapper attributes for calendar components."
  @spec table_attributes() :: String.t()
  def table_attributes do
    ~s(width="100%" cellpadding="0" cellspacing="0" style="#{table_style()}")
  end

  @spec table_style() :: String.t()
  defp table_style do
    "font-size: #{Tokens.font_size(:md)}; line-height: 1.6; color: #{Tokens.ink()};"
  end

  @doc "Legacy `<tr>` divider style."
  @spec table_row_style() :: String.t()
  def table_row_style, do: "border-bottom: 1px solid #{Tokens.hairline()};"

  @doc "Legacy `<td>` label cell style — uppercase eyebrow."
  @spec table_label_style() :: String.t()
  def table_label_style do
    "padding: 12px 16px 12px 0; font-weight: 600; color: #{Tokens.ink_muted()}; " <>
      "width: 38%; min-width: 100px; font-size: 12px; " <>
      "text-transform: uppercase; letter-spacing: 0.08em;"
  end

  @doc "Legacy `<td>` value cell style."
  @spec table_value_style() :: String.t()
  def table_value_style do
    "padding: 12px 0; color: #{Tokens.ink()}; word-break: break-word; " <>
      "font-size: 15px; font-weight: 500;"
  end
end
