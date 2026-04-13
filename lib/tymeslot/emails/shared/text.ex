defmodule Tymeslot.Emails.Shared.Text do
  @moduledoc """
  Typographic primitives for Tymeslot emails — 2026 redesign.

  Titles, centred body copy, micro-cap section labels, footer notes,
  dividers, and the troubleshooting link that sits below CTA buttons.
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles}
  alias Tymeslot.Security.UrlValidation

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  A content-area title block — an optional eyebrow kicker above a display-type
  title, and an optional subtitle below. Used inside the content area (the
  stage band covers the email-level headline).

  Options:
  - `:subtitle` — optional descriptive text below the title
  - `:emoji` — an emoji rendered inline as a prefix to the title
  - `:align` — `"left"`, `"center"`, `"right"` (default: `"left"`)
  - `:icon` — optional image URL for an icon above the title
  """
  @spec title_section(String.t(), keyword()) :: String.t()
  def title_section(title, opts \\ []) do
    subtitle = Keyword.get(opts, :subtitle)
    icon = Keyword.get(opts, :icon)
    emoji = Keyword.get(opts, :emoji)
    align = Keyword.get(opts, :align, "left")

    safe_title = Sanitise.sanitize_for_email(title)
    safe_subtitle = if subtitle, do: Sanitise.sanitize_for_email(subtitle)
    safe_emoji = if emoji, do: Sanitise.sanitize_for_email(emoji)

    icon_block =
      if icon,
        do: ~s(<mj-image src="#{icon}" width="40px" padding="0 0 10px 0" align="#{align}" />),
        else: ""

    title_html =
      if safe_emoji,
        do:
          ~s(<span style="display: inline-block; margin-right: 10px;">#{safe_emoji}</span>#{safe_title}),
        else: safe_title

    subtitle_block =
      if safe_subtitle do
        """
        <mj-text
          font-size="15px"
          color="#{Styles.ink_muted()}"
          align="#{align}"
          line-height="1.55"
          padding="6px 0 0 0"
          css-class="mobile-text"
        >
          #{safe_subtitle}
        </mj-text>
        """
      else
        ""
      end

    """
    <mj-section padding="16px 0 8px 0">
      <mj-column>
        #{icon_block}
        <mj-text
          font-size="26px"
          font-weight="800"
          color="#{Styles.ink()}"
          align="#{align}"
          line-height="1.15"
          letter-spacing="-0.02em"
          padding="0"
          css-class="mobile-heading"
        >
          #{title_html}
        </mj-text>
        #{subtitle_block}
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A small section title — upright uppercase micro-caps.
  Used to label a sub-section inside the content area.
  """
  @spec section_title(String.t(), keyword()) :: String.t()
  def section_title(text, opts \\ []) do
    padding = Keyword.get(opts, :padding, "20px 0 10px 0")
    color = Keyword.get(opts, :color, Styles.ink_muted())
    safe_text = Sanitise.sanitize_for_email(text)

    """
    <mj-section padding="#{padding}">
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{color}"
          align="center"
          letter-spacing="0.14em"
          text-transform="uppercase"
          css-class="mobile-eyebrow"
        >
          #{safe_text}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "Centered body text — for intros, closings, questions."
  @spec centered_text(String.t(), keyword()) :: String.t()
  def centered_text(text, opts \\ []) do
    font_size = Keyword.get(opts, :font_size, "16px")
    color = Keyword.get(opts, :color, Styles.ink_soft())
    padding = Keyword.get(opts, :padding, "4px 0 12px 0")
    safe_text = Sanitise.sanitize_for_email(text)

    """
    <mj-section padding="#{padding}">
      <mj-column>
        <mj-text
          font-size="#{font_size}"
          color="#{color}"
          line-height="1.6"
          align="center"
          css-class="mobile-text"
        >
          #{safe_text}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "Muted, centred, small — a system-level footer note."
  @spec system_footer_note(String.t()) :: String.t()
  def system_footer_note(text) do
    safe_text = Sanitise.sanitize_for_email(text)

    """
    <mj-section padding="12px 0 0 0">
      <mj-column>
        <mj-text
          font-size="13px"
          color="#{Styles.ink_muted()}"
          line-height="1.55"
          align="center"
          css-class="mobile-text"
        >
          #{safe_text}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "A thin horizontal divider — hairline color, full width."
  @spec divider(keyword()) :: String.t()
  def divider(opts \\ []) do
    color = Keyword.get(opts, :color, Styles.hairline())
    margin = Keyword.get(opts, :margin, "20px 0")

    """
    <mj-section padding="#{margin}">
      <mj-column>
        <mj-divider border-color="#{color}" border-width="1px" padding="0" />
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A troubleshooting link — shown below a button to help users who can't
  click it. URL is sanitised.
  """
  @spec troubleshooting_link(String.t()) :: String.t()
  def troubleshooting_link(url) do
    safe_url =
      case UrlValidation.validate_http_url(url) do
        :ok -> Sanitise.sanitize_for_email(url)
        {:error, _reason} -> Sanitise.sanitize_for_email(url)
      end

    """
    <mj-section padding="8px 0 0 0">
      <mj-column>
        <mj-text
          font-size="12px"
          color="#{Styles.ink_muted()}"
          line-height="1.6"
          align="center"
          padding="0 0 8px 0"
        >
          #{dgettext("emails", "Having trouble with the button? Copy and paste this link into your browser:")}
        </mj-text>
        <mj-text
          font-size="12px"
          align="center"
          color="#{Styles.ink_muted()}"
        >
          <a href="#{safe_url}" style="color: #{Styles.ink_muted()}; text-decoration: underline; word-break: break-all;">#{safe_url}</a>
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end
end
