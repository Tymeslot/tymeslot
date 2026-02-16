defmodule Tymeslot.Emails.Shared.ContentComponents do
  @moduledoc """
  Content-related MJML components for email templates.

  Implements design tokens for message containers:
  - **Message Box**: 10px radius, 20px padding, 700 weight for headers.
  - **Typography**: 15px body text with 22px line-height for readability.
  - **Theme**: Uses notification blue theme (#f0f9ff background, #0284c7 border).
  """

  alias Tymeslot.Emails.Shared.{SharedHelpers, Styles}
  alias Tymeslot.Security.UniversalSanitizer

  @doc """
  Generates a contact details card for administrative emails.

  The `row.value` is sanitized by default. To allow HTML (e.g., mailto links),
  pass `{:safe, html_string}` as the value, or include `safe_html: true` in the row map.
  """
  @spec contact_details_card(String.t(), String.t(), list(map())) :: String.t()
  def contact_details_card(title, _email, rows) do
    safe_title = SharedHelpers.sanitize_for_email(title)

    table_rows =
      Enum.map_join(rows, "\n", fn row ->
        safe_label = SharedHelpers.sanitize_for_email(row.label)

        # Sanitize value by default, but allow safe HTML opt-in
        safe_value =
          cond do
            # Handle {:safe, html} tuple for explicit safe HTML
            is_tuple(row.value) and tuple_size(row.value) == 2 and elem(row.value, 0) == :safe ->
              elem(row.value, 1)

            # Handle safe_html: true flag
            Map.get(row, :safe_html, false) ->
              row.value

            # Default: sanitize all user input
            true ->
              SharedHelpers.sanitize_for_email(row.value)
          end

        """
        <tr>
          <td style="padding: 4px 0; font-weight: 600; color: #{Styles.text_color(:secondary)}; width: 100px;">#{safe_label}:</td>
          <td style="padding: 4px 0; color: #{Styles.text_color(:primary)};">#{safe_value}</td>
        </tr>
        """
      end)

    """
    <mj-section
      background-color="#{Styles.background_color(:white)}"
      border-radius="#{Styles.card_radius()}"
      padding="20px"
      border="1px solid #{Styles.border_color(:subtle)}"
    >
      <mj-column>
        <mj-text font-size="18px" font-weight="600" color="#{Styles.text_color(:primary)}" padding-bottom="12px">
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
  Generates a card for displaying long message content.
  Uses UniversalSanitizer for enhanced security against XSS and injection attacks.
  """
  @spec message_content_card(String.t(), String.t()) :: String.t()
  def message_content_card(title, message) do
    safe_title = SharedHelpers.sanitize_for_email(title)

    # Use UniversalSanitizer for the message content
    # We allow basic HTML if it was already intended, but sanitize it heavily
    sanitized_message =
      case UniversalSanitizer.sanitize_and_validate(message,
             allow_html: true,
             on_too_long: :truncate
           ) do
        {:ok, sanitized} -> sanitized
        {:error, _reason} -> SharedHelpers.sanitize_for_email(message)
      end

    escaped_message = String.replace(sanitized_message, "\n", "<br>")

    """
    <mj-section
      background-color="#{Styles.background_color(:white)}"
      border-radius="#{Styles.card_radius()}"
      padding="20px"
      border="1px solid #{Styles.border_color(:subtle)}"
    >
      <mj-column>
        <mj-text font-size="18px" font-weight="600" color="#{Styles.text_color(:primary)}" padding-bottom="10px">
          #{safe_title}
        </mj-text>
        <mj-text
          font-size="15px"
          line-height="1.6"
          color="#{Styles.text_color(:dark)}"
          background-color="#{Styles.background_color(:slate)}"
          border-radius="8px"
          padding="16px"
        >
          #{escaped_message}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates an attendee message box if a message is provided.
  Uses UniversalSanitizer for security.
  """
  @spec attendee_message_box(String.t()) :: String.t()
  def attendee_message_box(message) when is_binary(message) and message != "" do
    # Use UniversalSanitizer for the message content
    sanitized_message =
      case UniversalSanitizer.sanitize_and_validate(message,
             allow_html: false,
             on_too_long: :truncate
           ) do
        {:ok, sanitized} -> sanitized
        {:error, _reason} -> SharedHelpers.sanitize_for_email(message)
      end

    """
    <mj-section
      padding="8px 0"
      background-color="#{Styles.notification_color(:bg_blue)}"
      border="1px solid #{Styles.notification_color(:border_blue)}"
      border-radius="10px"
    >
      <mj-column>
        <mj-text
          font-size="14px"
          font-weight="700"
          color="#{Styles.notification_color(:text_blue)}"
          padding="0 0 4px 0"
        >
          Message from Attendee
        </mj-text>
        <mj-text
          font-size="14px"
          line-height="20px"
          color="#{Styles.notification_color(:link_blue)}"
        >
          "#{sanitized_message}"
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  def attendee_message_box(_message), do: ""
end
