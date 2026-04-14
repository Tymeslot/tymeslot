defmodule Tymeslot.Emails.Shared.Layouts do
  @moduledoc """
  High-level MJML layouts for Tymeslot emails — 2026 redesign.

  Two layouts:

  - `transactional_layout/2` wraps content in the signature `MjmlEmail` frame,
    which opens with an intent stage band and an organiser strip. Used by
    meeting emails.
  - `system_layout/2` wraps content in a system frame — a stage band with the
    Tymeslot wordmark, a warm surface, and a hairline footer. Used by account
    emails (verification, password reset, subscription, etc).

  Both layouts require the caller to declare `:intent` and `:eyebrow`. There
  is no inference and no default — the template knows what it is.
  """

  alias Tymeslot.Emails.Shared.{Frame, MjmlEmail, Sanitise, Stage, Styles, Urls}

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  The transactional layout. `opts` is either a keyword list or a map of
  organiser details (name, avatar_url, title, intent, eyebrow, stage_title,
  stage_subtitle). `:intent` and `:eyebrow` are required.
  """
  @spec transactional_layout(String.t(), MjmlEmail.organizer_details() | keyword()) ::
          String.t()
  def transactional_layout(content, opts \\ []) do
    organizer_details =
      case opts do
        list when is_list(list) -> Map.new(list)
        map when is_map(map) -> map
      end

    MjmlEmail.base_mjml_template(content, organizer_details)
  end

  @doc """
  The system layout — used for account emails with no per-organiser identity.

  Required opts:
  - `:intent` — the email's intent atom (`:confirmed`, `:alert`, `:cancelled`)
  - `:eyebrow` — the short label shown above the stage title

  Optional opts:
  - `:title` — the HTML `<title>` (default: `"Tymeslot"`)
  - `:preview` — the inbox preview text
  - `:stage_title` — headline in the stage band (default: the `:title`)
  - `:stage_subtitle` — optional supporting line
  """
  @spec system_layout(String.t(), keyword()) :: String.t()
  def system_layout(content, opts) do
    intent = fetch_required!(opts, :intent)
    eyebrow = fetch_required!(opts, :eyebrow)
    raw_title = Keyword.get(opts, :title, "Tymeslot")
    title = Sanitise.sanitize_for_email(raw_title)

    preview =
      Sanitise.sanitize_for_email(
        Keyword.get(opts, :preview, "Important notification from Tymeslot")
      )

    stage_title = Keyword.get(opts, :stage_title, raw_title)
    stage_subtitle = Keyword.get(opts, :stage_subtitle)

    Frame.wrap(%{
      title: title,
      preview: preview,
      pre_card: MjmlEmail.logo_header(),
      stage: Stage.stage_band(intent, eyebrow, stage_title, stage_subtitle),
      header: "",
      body: content,
      footer: system_footer()
    })
  end

  @doc """
  A simple, content-focused layout for administrative or internal notifications.

  Required opts:
  - `:intent` — the email's intent
  - `:eyebrow` — the stage-band label
  - `:title` — the HTML title and stage headline
  """
  @spec simple_layout(String.t(), keyword()) :: String.t()
  def simple_layout(content, opts) do
    intent = fetch_required!(opts, :intent)
    eyebrow = fetch_required!(opts, :eyebrow)
    raw_title = fetch_required!(opts, :title)
    safe_title = Sanitise.sanitize_for_email(raw_title)

    header_block =
      case Keyword.get(opts, :header) do
        nil ->
          ""

        h ->
          ~s(<mj-text font-size="18px" font-weight="700" padding-bottom="12px" color="#{Styles.ink()}">#{Sanitise.sanitize_for_email(h)}</mj-text>)
      end

    body = """
    <mj-section padding="0">
      <mj-column>
        #{header_block}
        <mj-text line-height="1.6" color="#{Styles.ink_soft()}">
          #{content}
        </mj-text>
      </mj-column>
    </mj-section>
    """

    Frame.wrap(%{
      title: safe_title,
      preview: safe_title,
      stage: Stage.stage_band(intent, eyebrow, raw_title, nil),
      header: "",
      body: body,
      footer: system_footer()
    })
  end

  @spec fetch_required!(keyword(), atom()) :: term()
  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "Tymeslot.Emails.Shared.Layouts: missing required option `#{inspect(key)}`. " <>
                "Email layouts do not infer intent — the template must declare it."
    end
  end

  @spec system_footer() :: String.t()
  defp system_footer do
    """
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="0 0 20px 20px"
      padding="20px 28px"
    >
      <mj-column>
        <mj-text
          color="#{Styles.ink_muted()}"
          font-size="12px"
          align="center"
          line-height="1.7"
          letter-spacing="0.02em"
        >
          © #{Date.utc_today().year} <a href="#{Urls.get_app_url()}" class="wordmark" style="color: #{Styles.ink()}; text-decoration: none; font-weight: 800;">Tymeslot</a> · #{dgettext("emails", "scheduling that respects your time")}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end
end
