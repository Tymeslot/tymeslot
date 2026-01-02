defmodule Tymeslot.Emails.Shared.ContentComponents do
  @moduledoc """
  Content-related MJML components for email templates.
  Handles message boxes, notifications, and text-heavy content sections.
  """

  alias Tymeslot.Emails.Shared.{SharedHelpers, Styles}

  @doc """
  Generates an attendee message box if a message is provided.
  """
  @spec attendee_message_box(String.t()) :: String.t()
  def attendee_message_box(message) when is_binary(message) and message != "" do
    sanitized_message = SharedHelpers.sanitize_for_email(message)

    """
    <mj-wrapper padding="8px 0">
      <mj-section 
        background-color="#{Styles.notification_color(:bg_blue)}" 
        border="1px solid #{Styles.notification_color(:border_blue)}" 
        border-radius="6px" 
        padding="16px"
      >
        <mj-column>
          <mj-text 
            font-size="14px" 
            font-weight="600" 
            color="#{Styles.notification_color(:text_blue)}" 
            padding="0 0 8px 0"
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
    </mj-wrapper>
    """
  end

  def attendee_message_box(_), do: ""
end
