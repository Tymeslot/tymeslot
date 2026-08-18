defmodule Tymeslot.Emails.Shared.Styles.BrandPalette do
  @moduledoc """
  Derives the email brand colour family from a single seed colour.

  Self-hosted instances can replace the stock turquoise with their own brand
  colour (see `Tymeslot.AppSettings`). An admin supplies one hex value; the
  remaining three tokens of the family — `deep`, `ink`, and `tint` — are
  derived here so the family stays internally consistent whatever the seed.

  Only the `:confirmed` family is derivable. Amber and rose are semantic
  signals rather than decoration: an admin who recoloured `:cancelled` to
  their brand colour would produce a cancellation email that reads as a
  confirmation. `Tymeslot.Emails.Shared.Styles.Tokens` keeps those two fixed.

  ## Derivation

  The transforms are calibrated against the hand-tuned turquoise family, so
  seeding with the stock accent reproduces it closely enough that the
  difference does not survive an inbox:

    * `accent` — the seed, verbatim, never adjusted. This is the admin's
      brand colour as configured; it is preserved as-is because it is the
      instance's identity colour, not because anything renders it as text on
      a background. Surfaces that carry text — buttons, the stage band,
      links — use `deep` instead, so text stays legible.
    * `deep` — the seed darkened, for the stage band and link text.
    * `ink` — a heavily darkened, slightly desaturated variant, used as text
      on `tint`.
    * `tint` — a near-white wash of the seed's hue, used as a badge and callout
      background.

  ## Contrast

  `ink` and `deep` are both used *behind or beneath text*, so both are
  darkened until they clear a WCAG threshold. `deep` is the stage band's
  background: the band's 32px title is large and bold, but the same band also
  carries an 11px eyebrow and a 15px subtitle (see
  `Tymeslot.Emails.Shared.Stage`), neither of which meets the large-text
  carve-out, so `deep` is held to 4.5:1 — the same normal-text threshold as
  `ink` on `tint`. The stock family is stored already clearing both and
  `family/0` hands it back verbatim, so an instance that configures no accent
  never reaches the clamp at all. Seeding explicitly with the stock accent
  does engage it: the untouched transform lands `deep` at 3.6:1, and the
  clamp walks it down to 5.1:1. A seed that would otherwise produce
  unreadable emails, such as a pale yellow, is walked down much further.

  The seed itself is deliberately exempt. A light brand colour will give a
  low-contrast button, and the admin UI surfaces that ratio as a warning
  rather than silently darkening a colour the admin chose on purpose.

  ## Caching

  Derivation runs a bounded darkening loop, and `Tokens.intent/1` is called
  several times per rendered email. The result is memoised in a single
  `:persistent_term` slot keyed by the seed, so a stable accent derives once
  per boot and a changed accent simply replaces the slot.
  """

  alias Tymeslot.Emails.Branding
  alias Tymeslot.Utils.Colour

  @typedoc "The four colour tokens making up one intent family."
  @type family :: %{
          accent: String.t(),
          deep: String.t(),
          ink: String.t(),
          tint: String.t()
        }

  # Near-white text drawn on `band_color` (the `deep` token). Defined here
  # rather than in `Tokens` because the `deep` contrast clamp needs it, and a
  # second copy over there would let the two drift apart.
  @band_text "#f8f8f5"

  # Transform constants, calibrated against the stock turquoise family
  # (`Emails.Branding.stock_family/0`): seeding with the stock accent
  # reproduces it, so the default look is unchanged.
  @deep_lightness_drop 0.085
  @deep_saturation_gain 1.04
  @ink_lightness 0.20
  @ink_saturation_scale 0.88
  @tint_lightness 0.925
  @tint_saturation_ceiling 0.58

  # WCAG 2.1 minimums. Body text on `tint` is normal weight. The stage band's
  # title on `deep` is large and bold, but its eyebrow (11px) and subtitle
  # (15px) are not, so `deep` is held to the same normal-text floor rather
  # than the 3.0 large-text one.
  @ink_min_contrast 4.5
  @band_min_contrast 4.5

  @cache_key {__MODULE__, :derived_family}

  @doc "The near-white text colour drawn on a stage band."
  @spec band_text() :: String.t()
  def band_text, do: @band_text

  @doc """
  The brand colour family emails render with: derived from the configured
  accent when one is set and parses, the stock turquoise otherwise.

  This is a branding question — what family backs a self-hosted instance's
  emails — rather than a styling one. It is resolved here, against
  `Emails.Branding`, rather than the other way around, so `Tokens` (and this
  module) never point back up at a module that configures them.
  """
  @spec family() :: family()
  def family do
    case Branding.accent() do
      nil -> Branding.stock_family()
      seed -> derive(seed) || Branding.stock_family()
    end
  end

  @doc """
  Derives the brand family from a hex seed, or `nil` when the seed is not a
  valid hex colour so callers fall back to the stock family.

  ## Examples

      iex> Tymeslot.Emails.Shared.Styles.BrandPalette.derive("nonsense")
      nil
  """
  @spec derive(String.t() | nil) :: family() | nil
  def derive(seed_hex) do
    case Colour.normalise_hex(seed_hex) do
      nil -> nil
      hex -> cached(hex)
    end
  end

  defp cached(hex) do
    case :persistent_term.get(@cache_key, nil) do
      {^hex, family} ->
        family

      _stale_or_missing ->
        family = build(hex)
        :persistent_term.put(@cache_key, {hex, family})
        family
    end
  end

  defp build(hex) do
    {h, s, l} = Colour.hex_to_hsl(hex)

    tint =
      Colour.hsl_to_hex({h, min(s, @tint_saturation_ceiling), @tint_lightness})

    deep =
      {h, Colour.clamp(s * @deep_saturation_gain, 0.0, 1.0),
       Colour.clamp(l - @deep_lightness_drop, 0.0, 1.0)}
      |> Colour.darken_until_contrast(@band_text, @band_min_contrast)
      |> Colour.hsl_to_hex()

    ink =
      {h, Colour.clamp(s * @ink_saturation_scale, 0.0, 1.0), @ink_lightness}
      |> Colour.darken_until_contrast(tint, @ink_min_contrast)
      |> Colour.hsl_to_hex()

    %{accent: hex, deep: deep, ink: ink, tint: tint}
  end
end
