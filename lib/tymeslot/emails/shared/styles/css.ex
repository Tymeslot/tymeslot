defmodule Tymeslot.Emails.Shared.Styles.CSS do
  @moduledoc """
  Generates the MJML-embedded CSS for Tymeslot emails.

  Two public outputs:

  - `mjml_base_attributes/0` — the `<mj-attributes>` block that sets sensible
    defaults on `mj-all`, `mj-text`, `mj-section`, `mj-column`, `mj-button`,
    and `mj-table`.
  - `email_css_styles/0` — the `<mj-style>` block with base and mobile rules.

  No dark-mode rules. Email clients that honour `prefers-color-scheme` are
  rare, inconsistent, and break the moment a user uses Outlook.com
  (`[data-ogsc]`) or Thunderbird (which inverts instead). Rather than ship
  two parallel palettes, we pick a single light palette whose hex values
  survive client-forced inversion coherently — see `Tokens` for the notes.
  """

  alias Tymeslot.Emails.Shared.Styles.Tokens

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
      <mj-table font-family="#{Tokens.font_family()}" />
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

  # ============================================================================
  # BASE RULES — typography, wordmark, stage band, cards, badges
  # ============================================================================

  defp base_rules do
    """
    body { background: #{Tokens.canvas()}; }

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
      .mobile-card    { margin: 10px 0 !important; padding: 18px !important; }
      .stage-band     { padding: 24px 22px !important; }
      .stage-band-eyebrow { font-size: 10px !important; }
    }
    """
  end
end
