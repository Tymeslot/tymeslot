defmodule Tymeslot.Emails.Shared.Layouts do
  @moduledoc """
  High-level email layouts for Tymeslot (2026 Edition).

  This module provides semantic layouts that wrap email content in standardized structures,
  ensuring brand consistency across all transactional, system, and notification emails.
  """

  alias Tymeslot.Emails.Shared.{MjmlEmail, SharedHelpers, Styles}

  @doc """
  The standard transactional layout for meeting-related emails.
  Includes the organizer's avatar and name as the sender identity.
  """
  @spec transactional_layout(String.t(), map() | keyword()) :: String.t()
  def transactional_layout(content, opts \\ []) do
    organizer_details =
      case opts do
        list when is_list(list) -> Map.new(list)
        map when is_map(map) -> map
      end

    # Note: organizer_details are sanitized inside MjmlEmail.base_mjml_template
    MjmlEmail.base_mjml_template(content, organizer_details)
  end

  @doc """
  The system notification layout for account-related emails (verification, reset, etc).
  Features a centered logo and a more formal, system-oriented presentation.
  """
  @spec system_layout(String.t(), keyword()) :: String.t()
  def system_layout(content, opts \\ []) do
    title = SharedHelpers.sanitize_for_email(Keyword.get(opts, :title, "Tymeslot"))

    preview =
      SharedHelpers.sanitize_for_email(
        Keyword.get(opts, :preview, "Important notification from Tymeslot")
      )

    logo_data_uri = SharedHelpers.get_logo_data_uri()

    """
    <mjml>
      <mj-head>
        <mj-title>#{title}</mj-title>
        <mj-font name="Inter" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" />
        <mj-preview>#{preview}</mj-preview>
        #{Styles.mjml_base_attributes()}
        <mj-breakpoint width="480px" />
        #{Styles.email_css_styles()}
      </mj-head>
      <mj-body background-color="#{Styles.background_color(:slate)}" css-class="force-light-bg">
        <mj-wrapper padding="12px 12px" background-color="#{Styles.background_color(:slate)}">
          <mj-wrapper background-color="#{Styles.background_color(:white)}" border-radius="#{Styles.card_radius()}" padding="0" css-class="glass-card force-light-bg">
              <mj-section padding="20px 20px 12px 20px">
              <mj-column>
                <mj-image
                  src="#{logo_data_uri}"
                  width="180px"
                  alt="Tymeslot"
                  align="center"
                  href="#{SharedHelpers.get_app_url()}"
                />
              </mj-column>
            </mj-section>

            <mj-section padding="0 20px">
              <mj-column>
                <mj-divider border-color="#{Styles.border_color(:subtle)}" border-width="1px" padding="0" />
              </mj-column>
            </mj-section>

            <mj-wrapper padding="16px 20px 24px 20px" background-color="#{Styles.background_color(:white)}">
              #{content}
            </mj-wrapper>

            <mj-section
              background-color="#{Styles.background_color(:gray)}"
              border-radius="0 0 #{Styles.card_radius()} #{Styles.card_radius()}"
              padding="12px 20px"
            >
              <mj-column>
                <mj-text
                  color="#{Styles.text_color(:muted)}"
                  font-size="13px"
                  align="center"
                  line-height="20px"
                >
                  © #{Date.utc_today().year} <a href="#{SharedHelpers.get_app_url()}" style="color: #{Styles.component_color(:link)}; text-decoration: none; font-weight: 600;">Tymeslot</a>. All rights reserved.
                </mj-text>
              </mj-column>
            </mj-section>
          </mj-wrapper>
        </mj-wrapper>
      </mj-body>
    </mjml>
    """
  end

  @doc """
  A simple, content-focused layout for administrative or internal notifications.
  """
  @spec simple_layout(String.t(), keyword()) :: String.t()
  def simple_layout(content, opts \\ []) do
    title = SharedHelpers.sanitize_for_email(Keyword.get(opts, :title, "Notification"))
    header = Keyword.get(opts, :header)
    safe_header = if header, do: SharedHelpers.sanitize_for_email(header)
    logo_data_uri = SharedHelpers.get_logo_data_uri()

    """
    <mjml>
      <mj-head>
        <mj-title>#{title}</mj-title>
        <mj-font name="Inter" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" />
        #{Styles.mjml_base_attributes()}
        #{Styles.email_css_styles()}
      </mj-head>
      <mj-body background-color="#{Styles.background_color(:light)}">
        <mj-section padding="8px 0">
          <mj-column>
            <mj-image src="#{logo_data_uri}" width="160px" align="center" />
          </mj-column>
        </mj-section>
        <mj-section background-color="white" padding="20px" border-radius="8px">
          <mj-column>
            #{if header, do: "<mj-text font-size='17px' font-weight='700' padding-bottom='12px'>#{safe_header}</mj-text>", else: ""}
            <mj-text line-height="1.5">
              #{content}
            </mj-text>
          </mj-column>
        </mj-section>
        <mj-section padding="8px 0">
          <mj-column>
            <mj-text align="center" font-size="12px" color="#{Styles.text_color(:muted)}">
              Sent via Tymeslot
            </mj-text>
          </mj-column>
        </mj-section>
      </mj-body>
    </mjml>
    """
  end
end
