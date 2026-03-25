defmodule Tymeslot.Emails.Shared.MjmlEmail do
  @moduledoc """
  Base module for MJML email templates.

  Provides structural design tokens and layout helpers that implement the
  Tymeslot redesign (January 2026).

  ## Layout Structure
  - **Wrapper**: 24px horizontal padding on mobile, 12px gutter.
  - **Container**: 12px border radius, white background.
  - **Header**: 56px circular avatar, bold 20px organizer name.
  - **Content**: 24px - 28px vertical padding for clear hierarchy.
  - **Footer**: 12px bottom radius, subtle gray background, 13px text.

  ## Brand Assets
  - Uses Google Fonts Inter with weights 400-800.
  - Consistent SVG-based default avatars.
  """

  import Swoosh.Email
  alias Tymeslot.Emails.Shared.{AvatarHelper, SharedHelpers, Styles}
  alias Tymeslot.Security.UrlValidation

  @doc """
  Compiles MJML template to HTML.
  """
  @spec compile_mjml(String.t()) :: String.t()
  def compile_mjml(mjml_content) do
    case Mjml.to_html(mjml_content) do
      {:ok, html} -> html
      {:error, errors} -> raise "MJML compilation failed: #{inspect(errors)}"
    end
  end

  @doc """
  Creates a base email with common settings.
  """
  @spec base_email() :: Swoosh.Email.t()
  def base_email do
    new()
    |> from({fetch_from_name(), fetch_from_email()})
    |> put_provider_option(:track_opens, true)
    |> put_provider_option(:track_links, "HtmlAndText")
  end

  @doc """
  Gets the from email address.
  """
  @spec fetch_from_email() :: String.t()
  def fetch_from_email do
    get_config_email_setting(:from_email)
  end

  @doc """
  Gets the from name.
  """
  @spec fetch_from_name() :: String.t()
  def fetch_from_name do
    get_config_email_setting(:from_name)
  end

  defp get_config_email_setting(key) do
    case Application.get_env(:tymeslot, :email) do
      config when is_list(config) -> config[key]
      _other -> nil
    end
  end

  @doc """
  Modern MJML base template with 2026 design aesthetics.

  Features:
  - Refined glassmorphism-inspired styling
  - Better visual hierarchy with gradient accents
  - Enhanced spacing and rounded corners
  - Improved dark mode compatibility
  - Professional header with larger avatar
  """
  @spec base_mjml_template(String.t(), map() | nil) :: String.t()
  def base_mjml_template(content, organizer_details \\ nil) do
    # Use provided organizer details or fall back to defaults
    organizer_name =
      SharedHelpers.sanitize_for_email(organizer_details[:name] || fetch_from_name())

    organizer_avatar_url =
      case organizer_details[:avatar_url] do
        nil ->
          AvatarHelper.generate_default_avatar(organizer_name)

        url when is_binary(url) ->
          case UrlValidation.validate_http_url(url) do
            :ok -> SharedHelpers.sanitize_for_email(url)
            _other -> AvatarHelper.generate_default_avatar(organizer_name)
          end

        _other ->
          AvatarHelper.generate_default_avatar(organizer_name)
      end

    organizer_title = SharedHelpers.sanitize_for_email(organizer_details[:title] || "Tymeslot")

    """
    <mjml>
      <mj-head>
        <mj-title>Message from #{organizer_name}</mj-title>
        <mj-font name="Inter" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" />
        <mj-preview>#{organizer_name} sent you a message via Tymeslot</mj-preview>
        #{Styles.mjml_base_attributes()}
        <mj-breakpoint width="480px" />
        #{Styles.email_css_styles()}
      </mj-head>
      <mj-body background-color="#f4f4f5" css-class="force-light-bg">
        <mj-wrapper padding="12px 12px" background-color="#f4f4f5">
          <mj-wrapper background-color="#ffffff" border-radius="16px" padding="0" css-class="glass-card force-light-bg">
            <mj-section padding="16px 20px 8px 20px">
              <mj-group>
                <mj-column width="20%" vertical-align="middle">
                  <mj-image
                    src="#{organizer_avatar_url}"
                    width="44px"
                    height="44px"
                    border-radius="22px"
                    alt="#{organizer_name}"
                    align="center"
                    css-class="shadow-soft"
                  />
                </mj-column>
                <mj-column width="80%" vertical-align="middle">
                  <mj-text
                    font-size="17px"
                    font-weight="700"
                    padding="0 0 2px 0"
                    align="left"
                    line-height="1.2"
                    color="#18181b"
                    css-class="force-light-text"
                  >
                    #{organizer_name}
                  </mj-text>
                  <mj-text
                    font-size="12px"
                    color="#71717a"
                    padding="0"
                    align="left"
                    line-height="14px"
                  >
                    #{organizer_title}
                  </mj-text>
                </mj-column>
              </mj-group>
            </mj-section>

            <mj-section padding="0 20px">
              <mj-column>
                <mj-divider
                  border-color="#e4e4e7"
                  border-width="1px"
                  padding="0"
                />
              </mj-column>
            </mj-section>

            <mj-wrapper padding="12px 20px 20px 20px" background-color="#ffffff">
              #{content}
            </mj-wrapper>

            <mj-section
              background-color="#f9fafb"
              border-radius="0 0 16px 16px"
              padding="12px 20px"
            >
              <mj-column>
                <mj-text
                  color="#71717a"
                  font-size="13px"
                  align="center"
                  line-height="20px"
                >
                  Powered by <a href="#{SharedHelpers.get_app_url()}" style="color: #14b8a6; text-decoration: none; font-weight: 600;">Tymeslot</a>
                </mj-text>
              </mj-column>
            </mj-section>
          </mj-wrapper>
        </mj-wrapper>
      </mj-body>
    </mjml>
    """
  end
end
