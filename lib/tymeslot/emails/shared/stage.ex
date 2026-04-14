defmodule Tymeslot.Emails.Shared.Stage do
  @moduledoc """
  The **stage band** — Tymeslot's 2026 signature opening for every email.

  A stage band is a full-width section coloured by an intent gradient. It carries
  three typographic elements:

  1. A tiny **eyebrow** label (e.g. "Confirmed", "Heads up", "Cancelled")
  2. A bold **title** (the headline of the email)
  3. An optional **subtitle** (context or personalisation)

  The intent (`:confirmed`, `:alert`, `:cancelled`) drives the band colour
  and the ink contrast — picked from `Tymeslot.Emails.Shared.Styles.intent/1`.

  Stage bands are used by both the transactional layout (as the very first
  element, above the organiser strip) and the system layout (as the header,
  replacing the centred logo).
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles}

  # Decorative divider overlay — a translucent white line at the top of
  # coloured stage bands. Keeps visual separation on any intent background.
  @band_border_overlay "rgba(255, 255, 255, 0.14)"

  @doc """
  Renders a stage band section.

  `intent` is an atom — see `Styles.intent/1`.

  String arguments (eyebrow, title, subtitle) are sanitised inside this
  function — callers do not need to pre-sanitise them.
  """
  @spec stage_band(atom(), String.t(), String.t(), String.t() | nil) :: String.t()
  def stage_band(intent, eyebrow, title, subtitle \\ nil) do
    tokens = Styles.intent(intent)
    safe_eyebrow = Sanitise.sanitize_for_email(eyebrow)
    safe_title = Sanitise.sanitize_for_email(title)

    subtitle_block =
      case subtitle do
        nil ->
          ""

        s ->
          safe_subtitle = Sanitise.sanitize_for_email(s)

          """
          <mj-text
            padding="12px 0 0 0"
            color="#{tokens.band_text}"
            font-size="15px"
            line-height="1.55"
            align="left"
            css-class="mobile-text"
          >
            <span style="opacity: 0.92;">#{safe_subtitle}</span>
          </mj-text>
          """
      end

    """
    <mj-section
      background-color="#{tokens.band_color}"
      padding="32px 32px 28px 32px"
      border-radius="20px 20px 0 0"
      border-top="1px solid #{@band_border_overlay}"
      css-class="stage-band"
    >
      <mj-column>
        <mj-text
          padding="0 0 14px 0"
          color="#{tokens.band_text}"
          font-size="11px"
          font-weight="700"
          align="left"
          letter-spacing="0.18em"
          text-transform="uppercase"
          css-class="stage-band-eyebrow mobile-eyebrow"
        >
          <span style="opacity: 0.78;">#{dot()} #{safe_eyebrow}</span>
        </mj-text>
        <mj-text
          padding="0"
          color="#{tokens.band_text}"
          font-size="#{Styles.font_size(:display)}"
          font-weight="800"
          align="left"
          line-height="1.08"
          letter-spacing="-0.025em"
          css-class="stage-band-title mobile-heading"
        >
          #{safe_title}
        </mj-text>
        #{subtitle_block}
      </mj-column>
    </mj-section>
    """
  end

  defp dot do
    ~s(<span style="display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: currentColor; vertical-align: middle; margin-right: 8px; opacity: 0.6;"></span>)
  end

  @doc """
  Renders a compact stage band — shorter, no subtitle. Used for system emails
  where the content is short and we want to keep the fold above the CTA.
  """
  @spec compact_stage(atom(), String.t(), String.t()) :: String.t()
  def compact_stage(intent, eyebrow, title) do
    stage_band(intent, eyebrow, title, nil)
  end
end
