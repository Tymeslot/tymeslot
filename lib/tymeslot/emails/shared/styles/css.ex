defmodule Tymeslot.Emails.Shared.Styles.CSS do
  @moduledoc """
  Generates the MJML-embedded CSS for Tymeslot emails.

  Two public outputs:

  - `mjml_base_attributes/0` — the `<mj-attributes>` block that sets sensible
    defaults on `mj-all`, `mj-text`, `mj-section`, `mj-column`, `mj-button`,
    and `mj-table`.
  - `email_css_styles/0` — the `<mj-style>` block with base and mobile rules.
  - `dark_mode_styles/0` — the `prefers-color-scheme: dark` stylesheet, built
    by `DarkMode` from the light-to-dark colour map below.

  Clients that ignore `prefers-color-scheme` (Gmail, Outlook.com) keep the
  light palette or apply their own forced inversion, which the light palette
  is chosen to survive; see `Tokens` for the notes.
  """

  alias Tymeslot.Emails.Shared.Styles.{DarkMode, Tokens}
  alias Tymeslot.Utils.Colour

  @intents [:confirmed, :alert, :cancelled]

  # How much of an intent's accent tints the dark surface for its callout and
  # badge backgrounds: enough to read as the intent. A luminous custom accent
  # (a yellow) is backed off in steps until the quietest ink still clears AA.
  @dark_tint_strength 0.18
  @dark_tint_step 0.02

  # Accent and deep text clear AA; the intent's ink is its strongest text, so
  # it clears AAA, matching how it reads on the light side.
  @dark_text_contrast 4.5
  @dark_ink_contrast 7.0

  @doc """
  The `<mj-attributes>` block with global defaults — font, text, section,
  column, button, table.
  """
  @spec mjml_base_attributes() :: String.t()
  def mjml_base_attributes do
    """
    <mj-attributes>
      <mj-all font-family="#{Tokens.font_family()}" />
      <mj-text font-size="#{Tokens.font_size(:md)}" line-height="1.6" color="#{Tokens.ink()}" padding="0" />
      <mj-section padding="0" />
      <mj-column padding="0" />
      <mj-button font-family="#{Tokens.font_family()}" padding="0" />
      <mj-table font-family="#{Tokens.font_family()}" color="#{Tokens.ink()}" />
    </mj-attributes>
    """
  end

  @doc """
  The `<mj-style>` block — base typography, card/badge rules, mobile.
  """
  @spec email_css_styles() :: String.t()
  def email_css_styles do
    """
    <mj-style>
      #{base_rules()}
      #{mobile_styles()}
    </mj-style>
    """
  end

  @doc """
  The dark-mode `<style>` element. Rendered on every call because the
  `:confirmed` family follows the configured brand accent.
  """
  @spec dark_mode_styles() :: String.t()
  def dark_mode_styles do
    families = Enum.map(@intents, &{&1, Tokens.intent(&1)})
    tints = Map.new(families, fn {intent, tokens} -> {intent, dark_tint(tokens)} end)

    # Intent text can land on any intent's tint (a rose link inside an amber
    # callout), so every intent's text is lit against the lightest of them.
    backdrop =
      Enum.max_by([Tokens.dark(:canvas_soft) | Map.values(tints)], &Colour.relative_luminance/1)

    intents =
      Enum.map(families, fn {intent, tokens} ->
        {intent, dark_intent(tokens, tints[intent], backdrop)}
      end)

    DarkMode.stylesheet(%{
      text:
        neutral_pairs([:ink, :ink_soft, :ink_muted, :ink_whisper]) ++
          Enum.flat_map(intents, fn {_intent, dark} -> dark.text end),
      background:
        neutral_pairs([:canvas, :canvas_soft, :surface, :hairline]) ++
          Enum.map(intents, fn {_intent, dark} -> dark.tint end),
      border: neutral_pairs([:hairline, :hairline_soft]),
      keep_text: Enum.map(intents, fn {intent, _dark} -> {Tokens.intent_accent_deep(intent), Tokens.ink()} end),
      rules: dark_class_rules(intents)
    })
  end

  defp neutral_pairs(keys) do
    Enum.map(keys, &{apply(Tokens, &1, []), Tokens.dark(&1)})
  end

  defp dark_tint(tokens, strength \\ @dark_tint_strength) do
    tint = mix(tokens.accent, Tokens.dark(:surface), strength)

    if strength <= 0 or
         Colour.contrast_ratio(Tokens.dark(:ink_whisper), tint) >= @dark_text_contrast do
      tint
    else
      dark_tint(tokens, strength - @dark_tint_step)
    end
  end

  # The intent's three text colours, lightened until they read against
  # `backdrop`, the lightest dark surface text can sit on.
  defp dark_intent(tokens, tint, backdrop) do
    ink = readable(tokens.accent_ink, backdrop, @dark_ink_contrast)
    link = readable(tokens.accent_deep, backdrop, @dark_text_contrast)

    %{
      tint: {tokens.tint, tint},
      ink: ink,
      link: link,
      text: [
        {tokens.accent, readable(tokens.accent, backdrop, @dark_text_contrast)},
        {tokens.accent_deep, link},
        {tokens.accent_ink, ink}
      ]
    }
  end

  defp readable(hex, backdrop, minimum) do
    hex
    |> Colour.hex_to_hsl()
    |> Colour.lighten_until_contrast(backdrop, minimum)
    |> Colour.hsl_to_hex()
  end

  defp mix(top_hex, base_hex, weight) do
    {r1, g1, b1} = Colour.parse_hex(top_hex)
    {r2, g2, b2} = Colour.parse_hex(base_hex)
    blend = fn a, b -> round(a * weight + b * (1 - weight)) end
    Colour.to_hex({blend.(r1, r2), blend.(g1, g2), blend.(b1, b2)})
  end

  # Class-based rules from `base_rules/0` carry no inline colour for the
  # attribute selectors to match, so their dark values are set by class.
  # `body a` outranks the base `a` rule without `!important`, so a link with
  # an inline colour (a button) keeps it.
  defp dark_class_rules(intents) do
    confirmed = Keyword.fetch!(intents, :confirmed)

    badges =
      Enum.map_join([turquoise: :confirmed, amber: :alert, rose: :cancelled], "\n", fn {name, intent} ->
        dark = Keyword.fetch!(intents, intent)
        ".badge-#{name} { background: #{elem(dark.tint, 1)} !important; color: #{dark.ink} !important; }"
      end)

    """
    body a { color: #{confirmed.link}; }
    .glass-card {
      background: #{Tokens.dark(:surface)} !important;
      border-color: #{Tokens.dark(:hairline_soft)} !important;
      box-shadow: none !important;
    }
    .hairline { background: #{Tokens.dark(:hairline)} !important; }
    #{badges}
    """
  end

  # ============================================================================
  # BASE RULES — typography, wordmark, stage band, cards, badges
  # ============================================================================

  defp base_rules do
    """
    a {
      color: #{Tokens.intent_accent_deep(:confirmed)};
      text-decoration: none;
    }
    a:hover { color: #{Tokens.intent_accent(:confirmed)}; }

    .wordmark {
      font-family: #{Tokens.font_family()};
      font-weight: 800;
      letter-spacing: -0.02em;
    }

    .stage-band { padding: 28px 32px; }
    .stage-band-eyebrow {
      font-size: #{Tokens.font_size(:eyebrow)};
      font-weight: 700;
      letter-spacing: 0.14em;
      text-transform: uppercase;
      opacity: 0.78;
    }
    .stage-band-title {
      /* 32px matches Tokens.font_size(:display); this CSS rule is a fallback
         for clients that strip MJML inline attributes. */
      font-size: 32px;
      font-weight: 800;
      letter-spacing: -0.02em;
      line-height: 1.1;
    }

    .glass-card {
      background: #{Tokens.surface()};
      border: 1px solid #{Tokens.hairline_soft()};
      box-shadow: 0 1px 0 rgba(10, 18, 22, 0.04),
                  0 12px 40px rgba(10, 18, 22, 0.06);
    }

    .hairline {
      height: 1px;
      background: #{Tokens.hairline()};
      line-height: 1px;
      font-size: 1px;
    }

    .badge {
      display: inline-block;
      padding: 5px 12px;
      border-radius: #{Tokens.radius(:pill)};
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    #{badge_variants()}
    """
  end

  defp badge_variants do
    Enum.map_join(
      [
        {:turquoise, :confirmed},
        {:amber, :alert},
        {:rose, :cancelled}
      ],
      "\n",
      fn {name, intent} ->
        tokens = Tokens.intent(intent)
        ".badge-#{name} { background: #{tokens.tint}; color: #{tokens.accent_ink}; }"
      end
    )
  end

  # ============================================================================
  # MOBILE RULES — the @media (max-width: 480px) block
  # ============================================================================

  defp mobile_styles do
    """
    @media only screen and (max-width: 480px) {
      .mobile-display { font-size: 28px !important; line-height: 1.15 !important; }
      .mobile-heading { font-size: 22px !important; line-height: 1.25 !important; }
      .mobile-text    { font-size: 15px !important; line-height: 1.55 !important; }
      .mobile-eyebrow { font-size: 10px !important; letter-spacing: 0.12em !important; }
      .mobile-button  { width: 100% !important; padding: 16px 24px !important; }
      .mobile-card    { padding: 18px !important; }
      .stage-band     { padding: 24px 22px !important; }
      .stage-band-eyebrow { font-size: 10px !important; }
    }
    """
  end
end
