defmodule Tymeslot.Emails.Shared.Frame do
  @moduledoc """
  The shared outer MJML scaffold for every Tymeslot email.

  Both the transactional layout (`MjmlEmail.base_mjml_template/2`) and the
  system layout (`Layouts.system_layout/2`) render the same outer shell —
  `<mjml>`, `<mj-head>` with the font and CSS, and an `<mj-body>` wrapping a
  glass-card inner wrapper. This module owns that scaffold so the two layouts
  only have to supply the sections that go inside.

  Sections (all already-rendered MJML strings):

  - `stage` — the top stage band (from `Stage.stage_band/4`)
  - `header` — anything that sits between the stage and the body (organiser
    strip, wordmark, or nothing)
  - `body` — the caller's content
  - `footer` — the footer strip
  """

  alias Tymeslot.Emails.Shared.Styles

  @type sections :: %{
          required(:title) => String.t(),
          required(:preview) => String.t(),
          required(:stage) => String.t(),
          required(:header) => String.t(),
          required(:body) => String.t(),
          required(:footer) => String.t(),
          optional(:pre_card) => String.t()
        }

  @doc "Renders the full MJML document from pre-rendered section strings."
  @spec wrap(sections()) :: String.t()
  def wrap(
        %{
          title: title,
          preview: preview,
          stage: stage,
          header: header,
          body: body,
          footer: footer
        } = sections
      ) do
    pre_card = Map.get(sections, :pre_card, "")

    """
    <mjml>
      <mj-head>
        <mj-title>#{title}</mj-title>
        <mj-font name="Inter" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" />
        <mj-preview>#{preview}</mj-preview>
        <mj-raw>
          <meta name="color-scheme" content="light dark" />
          <meta name="supported-color-schemes" content="light dark" />
        </mj-raw>
        #{Styles.mjml_base_attributes()}
        <mj-breakpoint width="480px" />
        #{Styles.email_css_styles()}
      </mj-head>
      <mj-body background-color="#{Styles.canvas()}" css-class="email-canvas">
        <mj-wrapper
          padding="20px 12px 32px 12px"
          background-color="#{Styles.canvas()}"
          css-class="email-canvas"
        >
          #{pre_card}
          <mj-wrapper
            background-color="#{Styles.surface()}"
            border-radius="20px"
            padding="0"
            css-class="glass-card email-surface"
          >
            #{stage}
            #{header}
            <mj-wrapper
              padding="8px 28px 24px 28px"
              background-color="#{Styles.surface()}"
              css-class="email-surface"
            >
              #{body}
            </mj-wrapper>
            #{footer}
          </mj-wrapper>
        </mj-wrapper>
      </mj-body>
    </mjml>
    """
  end
end
