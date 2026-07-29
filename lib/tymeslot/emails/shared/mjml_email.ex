defmodule Tymeslot.Emails.Shared.MjmlEmail do
  @moduledoc """
  Base MJML template for Tymeslot transactional emails (2026 redesign).

  ## Anatomy

  Every transactional email now opens with a **stage band** — a full-width
  intent-coloured section whose gradient and eyebrow label tell the reader what
  kind of email this is before they read a word. Underneath the stage band an
  **organiser strip** shows the avatar, name, and title on a neutral surface.
  Content flows below into a warm off-white card, and the email closes with a
  quiet hairline footer carrying the wordmark.

  The intent is declared by the caller — `:intent` and `:eyebrow` are required
  keys on `organizer_details`. There is no inference, no default, and no
  fallback: an email that doesn't know its own intent fails to render.
  """

  require Logger

  import Swoosh.Email

  alias Swoosh.Attachment
  alias Tymeslot.Emails.Shared.{AvatarHelper, Frame, Sanitise, Stage, Styles, Urls}
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Mailer.Providers
  alias Tymeslot.Security.UrlValidation

  use Gettext, backend: TymeslotWeb.Gettext

  @type organizer_details :: %{
          required(:intent) => Tokens.intent(),
          required(:eyebrow) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:avatar_url) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:stage_title) => String.t() | nil,
          optional(:stage_subtitle) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc "Compiles MJML to HTML, raising on error."
  @spec compile_mjml(String.t()) :: String.t()
  def compile_mjml(mjml_content) do
    case Mjml.to_html(mjml_content) do
      {:ok, html} -> html
      {:error, errors} -> raise "MJML compilation failed: #{inspect(errors)}"
    end
  end

  @typedoc """
  Tracking category. Controls open-tracking and link-rewriting, and on
  Postmark the message stream the email is routed through.

    * `:transactional` — confirmations, security alerts, receipts. No opens,
      no link rewriting, sent on the default `outbound` (transactional) stream.
      Safer for spam filters and respects user privacy.
    * `:lifecycle` — onboarding / billing nudges where engagement metrics are
      genuinely useful (welcome, trial ending, dunning). Opens on, links left
      untouched, still on `outbound`.
    * `:marketing` — bulk newsletters and announcements. Opens on, links
      rewritten in HTML and text, sent on the `broadcast` stream so reputation
      is isolated from transactional mail.

  `Tymeslot.Mailer.Providers.tracking_options/2` translates the category for
  whichever provider is configured. Only Postmark has message streams; on the
  other providers the stream half of the category has no equivalent and
  isolating bulk from transactional reputation is configured at the provider.
  """
  @type tracking :: Providers.tracking()

  @doc """
  Creates a base Swoosh email pre-configured for the given tracking category
  and with the Tymeslot logo attached inline (CID `tymeslot-logo`) so the
  system layout's logo header renders identically in every email client
  without needing an external URL.

  Defaults to `:transactional` — the safe choice for any email tied to a
  specific user action (booking confirmation, password reset, receipt).
  Override with `tracking: :lifecycle` or `tracking: :marketing` at the call
  site for templates that genuinely benefit from engagement metrics.
  """
  @spec base_email(keyword()) :: Swoosh.Email.t()
  def base_email(opts \\ []) do
    tracking = Keyword.get(opts, :tracking, :transactional)

    new()
    |> from({fetch_from_name(), fetch_from_email()})
    |> apply_tracking(tracking)
    |> attach_logo()
  end

  @spec apply_tracking(Swoosh.Email.t(), tracking()) :: Swoosh.Email.t()
  defp apply_tracking(email, category) do
    adapter = Application.get_env(:tymeslot, Tymeslot.Mailer, [])[:adapter]

    adapter
    |> Providers.tracking_options(category)
    |> Enum.reduce(email, fn {option, value}, email ->
      put_provider_option(email, option, value)
    end)
  end

  @logo_cid "tymeslot-logo"

  @doc "The Content-ID used for the inline Tymeslot logo attachment."
  @spec logo_cid() :: String.t()
  def logo_cid, do: @logo_cid

  @doc """
  Attaches the Tymeslot logo as an inline image. Swallowed silently if the
  PNG can't be read — the email still sends, the logo simply won't render.
  """
  @spec attach_logo(Swoosh.Email.t()) :: Swoosh.Email.t()
  def attach_logo(email) do
    case logo_bytes() do
      {:ok, bytes} ->
        attachment(
          email,
          Attachment.new(
            {:data, bytes},
            filename: "tymeslot-logo.png",
            content_type: "image/png",
            type: :inline,
            cid: @logo_cid
          )
        )

      :error ->
        Logger.warning(
          "Tymeslot logo not found — emails will render without inline logo",
          path: Application.app_dir(:tymeslot, "priv/static/images/brand/logo-with-text.png")
        )

        email
    end
  end

  @spec logo_bytes() :: {:ok, binary()} | :error
  defp logo_bytes do
    path = Application.app_dir(:tymeslot, "priv/static/images/brand/logo-with-text.png")

    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> :error
    end
  end

  @doc "Returns the configured from-email."
  @spec fetch_from_email() :: String.t()
  def fetch_from_email, do: get_config_email_setting(:from_email)

  @doc "Returns the configured from-name."
  @spec fetch_from_name() :: String.t()
  def fetch_from_name, do: get_config_email_setting(:from_name)

  defp get_config_email_setting(key) do
    case Application.get_env(:tymeslot, :email) do
      config when is_list(config) -> config[key]
      _other -> nil
    end
  end

  @doc """
  Renders the full MJML document for a transactional email.

  `organizer_details` carries the sender identity (organizer name, avatar,
  optional title) and, new in 2026, an optional `:intent` and `:eyebrow` to
  drive the stage band.
  """
  @spec base_mjml_template(String.t(), organizer_details()) :: String.t()
  def base_mjml_template(content, organizer_details) when is_map(organizer_details) do
    intent = fetch_required!(organizer_details, :intent)
    stage_eyebrow = fetch_required!(organizer_details, :eyebrow)

    raw_organizer_name = organizer_details[:name] || fetch_from_name()
    organizer_name = Sanitise.sanitize_for_email(raw_organizer_name)

    organizer_avatar_url = resolve_avatar(organizer_details[:avatar_url], organizer_name)

    organizer_title =
      Sanitise.sanitize_for_email(organizer_details[:title] || "Tymeslot")

    stage_title = organizer_details[:stage_title] || raw_organizer_name
    stage_subtitle = organizer_details[:stage_subtitle]

    Frame.wrap(%{
      title: "Message from #{organizer_name}",
      preview: "#{organizer_name} via Tymeslot",
      pre_card: logo_header(),
      stage: Stage.stage_band(intent, stage_eyebrow, stage_title, stage_subtitle),
      header: organizer_strip(organizer_avatar_url, organizer_name, organizer_title),
      body: content,
      footer: footer_strip()
    })
  end

  @doc """
  The shared inline-logo header rendered above the stage band. Used by both
  the transactional and system layouts so every email references the
  attached logo via `cid:#{@logo_cid}` and never falls back to a plain
  attachment.
  """
  @spec logo_header() :: String.t()
  def logo_header do
    """
    <mj-section
      padding="4px 0 22px 0"
      background-color="#{Styles.canvas()}"
      css-class="email-canvas"
    >
      <mj-column>
        <mj-image
          src="cid:#{@logo_cid}"
          alt="Tymeslot"
          href="#{Urls.get_app_url()}"
          width="150px"
          align="center"
          padding="0"
          border="0"
        />
      </mj-column>
    </mj-section>
    """
  end

  @spec fetch_required!(map(), atom()) :: term()
  defp fetch_required!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "Tymeslot.Emails.Shared.MjmlEmail: missing required organiser detail `#{inspect(key)}`. " <>
                "Transactional emails must declare `:intent` and `:eyebrow` at the call site."
    end
  end

  defp resolve_avatar(nil, organizer_name),
    do: AvatarHelper.generate_default_avatar(organizer_name)

  defp resolve_avatar(url, organizer_name) when is_binary(url) do
    case UrlValidation.validate_http_url(url) do
      :ok -> Sanitise.sanitize_for_email(url)
      _other -> AvatarHelper.generate_default_avatar(organizer_name)
    end
  end

  defp resolve_avatar(_other, organizer_name),
    do: AvatarHelper.generate_default_avatar(organizer_name)

  defp organizer_strip(avatar_url, name, title) do
    """
    <mj-section
      padding="18px 28px 14px 28px"
      background-color="#{Styles.surface()}"
      border-bottom="1px solid #{Styles.hairline()}"
      css-class="email-surface email-hairline-bottom"
    >
      <mj-group>
        <mj-column width="16%" vertical-align="middle">
          <mj-image
            src="#{avatar_url}"
            width="44px"
            height="44px"
            border-radius="22px"
            alt="#{name}"
            align="left"
            padding="0"
          />
        </mj-column>
        <mj-column width="84%" vertical-align="middle">
          <mj-text
            font-size="15px"
            font-weight="700"
            padding="0 0 2px 8px"
            align="left"
            line-height="1.2"
            color="#{Styles.ink()}"
            css-class="email-ink"
          >
            #{name}
          </mj-text>
          <mj-text
            font-size="12px"
            color="#{Styles.ink_muted()}"
            padding="0 0 0 8px"
            align="left"
            line-height="1.3"
            letter-spacing="0.02em"
            css-class="email-ink-muted"
          >
            #{title}
          </mj-text>
        </mj-column>
      </mj-group>
    </mj-section>
    """
  end

  defp footer_strip do
    """
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="0 0 20px 20px"
      padding="18px 28px"
      css-class="email-canvas-soft"
    >
      <mj-column>
        <mj-text
          color="#{Styles.ink_muted()}"
          font-size="12px"
          align="center"
          line-height="1.6"
          letter-spacing="0.02em"
          css-class="email-ink-muted"
        >
          #{dgettext("emails", "Sent with care by")}
          <a href="#{Urls.get_app_url()}" class="wordmark email-ink-link" style="color: #{Styles.ink()}; text-decoration: none; font-weight: 800;">Tymeslot</a>
          · #{dgettext("emails", "scheduling that respects your time")}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end
end
