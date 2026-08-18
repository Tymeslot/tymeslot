defmodule Tymeslot.Emails.Shared.Buttons do
  @moduledoc """
  Primary call-to-action buttons for Tymeslot emails — 2026 redesign.

  Pill-shaped, bold, single-CTA ethos. The button background comes from the
  caller-supplied `intent` — a button always matches the intent of the email
  it lives inside.
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles}
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Security.UrlValidation

  @type button_spec :: %{
          required(:text) => String.t(),
          required(:url) => String.t(),
          optional(:opts) => keyword(),
          optional(atom()) => term()
        }

  @doc """
  A primary action button — pill-shaped, bold, centred. The background colour
  comes from the supplied `intent`.

  Options:
  - `:size` — `:large`, `:medium`, `:small` (default: `:medium`)
  - `:full_width` — mobile responsiveness (default: `false`)
  - `:width` — explicit width (default: `"auto"`)
  """
  @spec action_button(Tokens.intent(), String.t(), String.t(), keyword()) :: String.t()
  def action_button(intent, text, url, opts \\ []) when is_atom(intent) do
    size = Keyword.get(opts, :size, :medium)
    full_width = Keyword.get(opts, :full_width, false)
    width = Keyword.get(opts, :width, "auto")

    """
    <mj-section padding="14px 0">
      <mj-column>
        #{button_markup(intent, text, url, size, full_width, width)}
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A horizontal group of buttons — renders them side-by-side via `mj-group`.
  Every button shares the same `intent`.
  """
  @spec action_button_group(Tokens.intent(), list(button_spec())) :: String.t()
  def action_button_group(intent, buttons) when is_atom(intent) do
    columns =
      Enum.map_join(buttons, "\n", fn button ->
        opts = Map.get(button, :opts, [])
        size = Keyword.get(opts, :size, :medium)
        full_width = Keyword.get(opts, :full_width, false)
        width = Keyword.get(opts, :width, "auto")

        """
        <mj-column>
          #{button_markup(intent, button.text, button.url, size, full_width, width)}
        </mj-column>
        """
      end)

    """
    <mj-section padding="14px 0">
      <mj-group>
        #{columns}
      </mj-group>
    </mj-section>
    """
  end

  defp button_markup(intent, text, url, size, full_width, width) do
    safe_text = Sanitise.sanitize_for_email(text)
    safe_url = sanitize_button_url(url)
    css_class = if full_width, do: "mobile-button", else: ""
    accent_deep = Styles.intent_accent_deep(intent)

    """
    <mj-button
      href="#{safe_url}"
      background-color="#{accent_deep}"
      color="#{Styles.button_text_color(accent_deep)}"
      border-radius="#{Styles.button_radius()}"
      font-size="#{Styles.font_size(:md)}"
      inner-padding="#{Styles.button_padding(size)}"
      width="#{width}"
      font-weight="700"
      letter-spacing="-0.01em"
      css-class="#{css_class}">
      #{safe_text}
    </mj-button>
    """
  end

  defp sanitize_button_url("mailto:" <> _rest = url), do: Sanitise.sanitize_for_email(url)

  defp sanitize_button_url(url) do
    case UrlValidation.validate_http_url(url) do
      :ok -> Sanitise.sanitize_for_email(url)
      _error -> "#"
    end
  end
end
