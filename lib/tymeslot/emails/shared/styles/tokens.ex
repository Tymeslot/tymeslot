defmodule Tymeslot.Emails.Shared.Styles.Tokens do
  @moduledoc """
  The design-token primitives for the 2026 email redesign.

  This module carries the raw values — colour palette, intent map, type scale,
  spacing, radii — and the lookup functions that turn token keys into values.
  Nothing in here emits CSS. `Tymeslot.Emails.Shared.Styles.CSS` does that.

  The palette is **inversion-survivable**: no pure whites, no pure blacks.
  Every base value sits a few steps off the extremes so that a client-forced
  inversion (Thunderbird, iOS Mail, Gmail Android) produces a coherent warm
  result rather than washed-out neon. There is no separate dark-mode
  stylesheet — the single palette carries both light and inverted clients.
  """

  alias Tymeslot.Emails.Shared.Styles.BrandPalette

  # ============================================================================
  # PALETTE — canvas, surfaces, ink, hairlines
  # ============================================================================

  # Light palette. Every value stays a few steps away from pure white and
  # pure black so a client-forced inversion still lands on readable colours:
  #   surface #fafaf6 → inverts to near-black with a warm tint
  #   ink     #111418 → inverts to warm cream, never glaring white
  # Contrast on the light side clears WCAG AA (≥4.5:1) for every text tier.
  @canvas "#f4f0e6"
  @canvas_soft "#ede7d4"
  @surface "#fafaf6"
  @hairline "#d5cfbe"
  @hairline_soft "#e4decb"

  @ink "#111418"
  @ink_soft "#2d3339"
  @ink_muted "#4a5058"
  @ink_whisper "#6d737a"

  # ============================================================================
  # BRAND ACCENTS — intent families
  # ============================================================================
  #
  # Only three families exist:
  #
  #   * Turquoise — the brand. Used for anything informational, welcome,
  #     reminder, invitation, trial, subscription, confirmation, or "all good".
  #     The stock turquoise family lives in `BrandPalette`, alongside the
  #     derivation it calibrates.
  #   * Amber    — the attention signal. Used when the reader needs to *act*
  #     but nothing is broken yet (payment reminders, integration health,
  #     security notifications, disputes filed, email change requests).
  #   * Rose     — the alarm signal. Used for actual bad states —
  #     cancellations, errors, failed payments, calendar sync failures,
  #     disputes lost, subscriptions cancelled.
  #
  # Every informational or neutral email uses the brand colour. Signal
  # colours only show up when they're genuinely signalling something.

  # `deep` backs the stage band and the button surface for each family, so it
  # carries text and has to clear 4.5:1 against it — the same floor
  # `BrandPalette` clamps derived families to. Rose's `deep` was darkened from
  # "#c44d3d" (4.41:1 against band text, a hair under) to reach it.
  #
  # Amber's `deep` is a known exception: it clears 4.5:1 for a button (dark ink
  # reads at 5.8:1) but only reaches 2.99:1 against the near-white stage-band
  # text. Fixing that means changing the alert band's colour, which is a design
  # decision outside the email-branding change that surfaced it.
  @amber %{accent: "#f59e0b", deep: "#d97706", ink: "#78350f", tint: "#fef3c7"}
  @rose %{accent: "#e26d5c", deep: "#bd493a", ink: "#7a2b22", tint: "#fbeeeb"}

  # ============================================================================
  # INTENTS — semantic categories describing the purpose of an email, each
  # bound to a brand family. Each intent exposes the same shape: accent,
  # accent_deep, accent_ink, tint, band_color, band_text — so callers never
  # care which family backs them. Intent is declared by the caller; there is
  # no fallback, no inference, and no string vocabulary.
  # ============================================================================

  # `:confirmed` is the only derivable family — a self-hosted instance can
  # replace the turquoise with its own brand colour. The other two stay fixed
  # because they carry meaning: see `BrandPalette` for why.
  @type intent :: :confirmed | :alert | :cancelled

  @type intent_tokens :: %{
          accent: String.t(),
          accent_deep: String.t(),
          accent_ink: String.t(),
          tint: String.t(),
          band_color: String.t(),
          band_text: String.t()
        }

  # ============================================================================
  # TYPOGRAPHY
  # ============================================================================

  @font_family "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"

  @font_sizes %{
    eyebrow: "11px",
    xs: "12px",
    sm: "14px",
    md: "16px",
    base: "16px",
    lg: "18px",
    xl: "20px",
    "2xl": "24px",
    "3xl": "30px",
    display: "32px",
    hero: "34px"
  }

  # ============================================================================
  # RADII
  # ============================================================================

  @radii %{sm: "8px", md: "14px", lg: "20px", pill: "999px"}

  # ============================================================================
  # PUBLIC GETTERS
  # ============================================================================

  @doc "Warm canvas — outer wrapper background of every email."
  @spec canvas() :: String.t()
  def canvas, do: @canvas

  @doc "Softer canvas — for the hero meeting card and footer."
  @spec canvas_soft() :: String.t()
  def canvas_soft, do: @canvas_soft

  @doc "Cream surface — for the main card and organizer strip."
  @spec surface() :: String.t()
  def surface, do: @surface

  @doc "Hairline — 1px dividers between sections."
  @spec hairline() :: String.t()
  def hairline, do: @hairline

  @doc "Soft hairline — subtle card borders."
  @spec hairline_soft() :: String.t()
  def hairline_soft, do: @hairline_soft

  @doc "Primary ink — display and body headings."
  @spec ink() :: String.t()
  def ink, do: @ink

  @doc "Soft ink — body paragraphs."
  @spec ink_soft() :: String.t()
  def ink_soft, do: @ink_soft

  @doc "Muted ink — labels, eyebrows, secondary metadata."
  @spec ink_muted() :: String.t()
  def ink_muted, do: @ink_muted

  @doc "Whisper ink — the quietest text (legal, tertiary)."
  @spec ink_whisper() :: String.t()
  def ink_whisper, do: @ink_whisper

  @doc "Inter-based font stack with platform fallbacks."
  @spec font_family() :: String.t()
  def font_family, do: @font_family

  @doc "Font size by semantic key."
  @spec font_size(atom()) :: String.t()
  def font_size(key), do: Map.fetch!(@font_sizes, key)

  @doc "Border radius by semantic key."
  @spec radius(:sm | :md | :lg | :pill) :: String.t()
  def radius(key), do: Map.fetch!(@radii, key)

  @doc """
  Full token map for an intent. Raises on unknown input — intents are
  declared by the caller, never inferred or guessed.

  `:confirmed` resolves against the configured brand accent, so a self-hosted
  instance that has set one gets its own colour everywhere the brand family
  is used. An unset or unparseable accent falls back to the hand-tuned
  turquoise, which is what ships by default.
  """
  @spec intent(intent()) :: intent_tokens()
  def intent(:confirmed), do: family_tokens(BrandPalette.family())
  def intent(:alert), do: family_tokens(@amber)
  def intent(:cancelled), do: family_tokens(@rose)

  defp family_tokens(family) do
    %{
      accent: family.accent,
      accent_deep: family.deep,
      accent_ink: family.ink,
      tint: family.tint,
      band_color: family.deep,
      band_text: BrandPalette.band_text()
    }
  end

  @doc "Shortcut for `intent(i).accent`."
  @spec intent_accent(intent()) :: String.t()
  def intent_accent(i), do: intent(i).accent

  @doc "Shortcut for `intent(i).accent_deep` — for hover states and bolder text."
  @spec intent_accent_deep(intent()) :: String.t()
  def intent_accent_deep(i), do: intent(i).accent_deep
end
