defmodule Tymeslot.Emails.Templates.ContactForm do
  @moduledoc """
  Contact form email template.
  """

  alias Swoosh.Email
  alias Tymeslot.Emails.Shared.MjmlEmail

  @doc """
  Renders a contact form submission email.
  """
  @spec contact_form_email(String.t(), String.t(), String.t(), String.t()) :: Swoosh.Email.t()
  def contact_form_email(sender_name, sender_email, subject, message) do
    mjml_content = render_mjml(sender_name, sender_email, subject, message)
    html_body = MjmlEmail.compile_mjml(mjml_content)

    MjmlEmail.base_email()
    |> Email.to({
      Application.get_env(:tymeslot, :email)[:from_name],
      Application.get_env(:tymeslot, :email)[:contact_recipient]
    })
    |> Email.reply_to({sender_name, sender_email})
    |> Email.subject("Contact Form: #{subject}")
    |> Email.html_body(html_body)
  end

  defp render_mjml(sender_name, sender_email, subject, message) do
    """
    <mjml>
      <mj-head>
        <mj-title>Contact Form Submission</mj-title>
        <mj-preview>New contact form message from #{sender_name}</mj-preview>
        <mj-attributes>
          <mj-all font-family="Inter, system-ui, -apple-system, sans-serif" />
          <mj-text color="#1f2937" line-height="1.6" />
        </mj-attributes>
        <mj-style>
          .glass-card {
            background: linear-gradient(135deg, rgba(255, 255, 255, 0.1), rgba(255, 255, 255, 0.05));
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 16px;
          }
          .gradient-bg {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
          }
        </mj-style>
      </mj-head>
      <mj-body background-color="#f8fafc">
        <!-- Header -->
        <mj-section background-color="transparent" padding="20px 0">
          <mj-column>
            <mj-text align="center" font-size="28px" font-weight="bold" color="#1e293b">
              Contact Form Submission
            </mj-text>
            <mj-text align="center" font-size="16px" color="#64748b">
              New message received via Tymeslot contact form
            </mj-text>
          </mj-column>
        </mj-section>

        <!-- Contact Details Card -->
        <mj-section background-color="white" border-radius="16px" padding="30px">
          <mj-column>
            <mj-text font-size="20px" font-weight="600" color="#1e293b" padding-bottom="20px">
              Contact Information
            </mj-text>

            <mj-table>
              <tr>
                <td style="padding: 8px 0; font-weight: 600; color: #475569; width: 100px;">Name:</td>
                <td style="padding: 8px 0; color: #1e293b;">#{sender_name}</td>
              </tr>
              <tr>
                <td style="padding: 8px 0; font-weight: 600; color: #475569;">Email:</td>
                <td style="padding: 8px 0; color: #1e293b;">
                  <a href="mailto:#{sender_email}" style="color: #14b8a6; text-decoration: none;">#{sender_email}</a>
                </td>
              </tr>
              <tr>
                <td style="padding: 8px 0; font-weight: 600; color: #475569;">Subject:</td>
                <td style="padding: 8px 0; color: #1e293b;">#{subject}</td>
              </tr>
            </mj-table>
          </mj-column>
        </mj-section>

        <!-- Message Content -->
        <mj-section background-color="white" border-radius="16px" padding="30px" padding-top="20px">
          <mj-column>
            <mj-text font-size="20px" font-weight="600" color="#1e293b" padding-bottom="15px">
              Message
            </mj-text>
            <mj-text
              font-size="16px"
              line-height="1.7"
              color="#3f3f46"
              background-color="#f8fafc"
              border-radius="8px"
              padding="20px"
            >
              #{String.replace(message, "\n", "<br>")}
            </mj-text>
          </mj-column>
        </mj-section>

        <!-- Action Buttons -->
        <mj-section background-color="transparent" padding="30px 0">
          <mj-column>
            <mj-button
              background-color="#14b8a6"
              color="white"
              font-size="16px"
              font-weight="600"
              border-radius="8px"
              padding="12px 24px"
              href="mailto:#{sender_email}?subject=Re: #{subject}"
            >
              Reply to #{sender_name}
            </mj-button>
          </mj-column>
        </mj-section>

        <!-- Footer -->
        <mj-section background-color="transparent" padding="20px 0">
          <mj-column>
            <mj-divider border-color="#e2e8f0" border-width="1px" />
            <mj-text align="center" font-size="14px" color="#64748b" padding-top="20px">
              This message was sent via the Tymeslot contact form<br>
              For inquiries, please contact #{Application.get_env(:tymeslot, :email)[:support_email]}
            </mj-text>
          </mj-column>
        </mj-section>
      </mj-body>
    </mjml>
    """
  end
end
