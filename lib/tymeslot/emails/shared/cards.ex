defmodule Tymeslot.Emails.Shared.Cards do
  @moduledoc """
  Content card and data-grid components for Tymeslot emails — 2026 redesign.

  Where `Callouts` draws the eye with a tinted background and an intent accent,
  `Cards` lay out structured information — key/value tables, long-form
  messages, compact info grids, and footer action rows. The surfaces sit on
  the warm canvas; the typography does the heavy lifting.
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles}
  alias Tymeslot.Security.UniversalSanitizer

  @type contact_row :: %{
          required(:label) => String.t(),
          required(:value) => String.t() | {:safe, String.t()},
          optional(:safe_html) => boolean()
        }

  @doc """
  A contact details card. `row.value` is sanitised by default; pass
  `{:safe, html}` or `%{safe_html: true, value: html}` to bypass.
  """
  @spec contact_details_card(String.t(), list(contact_row())) :: String.t()
  def contact_details_card(title, rows) do
    safe_title = Sanitise.sanitize_for_email(title)

    table_rows =
      Enum.map_join(rows, "\n", fn row ->
        safe_label = Sanitise.sanitize_for_email(row.label)
        safe_value = resolve_row_value(row)

        """
        <tr>
          <td style="padding: 10px 12px 10px 0; font-size: 11px; font-weight: 700; color: #{Styles.ink_muted()}; letter-spacing: 0.1em; text-transform: uppercase; width: 110px; vertical-align: top; border-bottom: 1px solid #{Styles.border_color(:subtle)};">#{safe_label}</td>
          <td style="padding: 10px 0; color: #{Styles.ink()}; font-size: 14px; font-weight: 500; vertical-align: top; border-bottom: 1px solid #{Styles.border_color(:subtle)};">#{safe_value}</td>
        </tr>
        """
      end)

    """
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="#{Styles.card_radius()}"
      padding="22px 24px"
      css-class="mobile-card"
    >
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.14em"
          text-transform="uppercase"
          padding="0 0 12px 0"
        >
          #{safe_title}
        </mj-text>
        <mj-table>
          #{table_rows}
        </mj-table>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A message content card — tinted, with a small kicker title and the body
  rendered as sanitised text with line breaks preserved.
  """
  @spec message_content_card(String.t(), String.t()) :: String.t()
  def message_content_card(title, message) do
    safe_title = Sanitise.sanitize_for_email(title)

    sanitized_message =
      case UniversalSanitizer.sanitize_and_validate(message,
             allow_html: true,
             on_too_long: :truncate
           ) do
        {:ok, sanitized} -> sanitized
        {:error, _reason} -> Sanitise.sanitize_for_email(message)
      end

    formatted = String.replace(sanitized_message, "\n", "<br>")

    """
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="#{Styles.card_radius()}"
      padding="22px 24px"
      css-class="mobile-card"
    >
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.14em"
          text-transform="uppercase"
          padding="0 0 12px 0"
        >
          #{safe_title}
        </mj-text>
        <mj-text
          font-size="15px"
          line-height="1.65"
          color="#{Styles.ink_soft()}"
          padding="0"
          css-class="mobile-text"
        >
          #{formatted}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp resolve_row_value(%{value: {:safe, html}}), do: html
  defp resolve_row_value(%{value: value, safe_html: true}), do: value
  defp resolve_row_value(%{value: value}), do: Sanitise.sanitize_for_email(value)
end
