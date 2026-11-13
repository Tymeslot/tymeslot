defmodule Tymeslot.Emails.Templates.BookingLink do
  @moduledoc """
  The host's own booking link, mailed to them on request: the link itself, a
  ready-made signature line and a QR code.

  The QR code is an inline attachment referenced by `cid:`, because many mail
  clients block `data:` images.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Attachment
  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{Buttons, Greeting, MjmlEmail, Sanitise, Styles}
  alias Tymeslot.Emails.Shared.{TemplateHelper, Text}
  alias Tymeslot.Utils.QrCode
  alias Tymeslot.Utils.UrlBuilder

  @intent :confirmed
  # The cid is the filename: SendGrid derives the content id from the filename
  # and Mailgun keys inline files by it.
  @qr_filename "booking-link-qr.png"

  @doc """
  The email, addressed and rendered in the host's locale. `booking_url` is
  the absolute URL of the host's booking page.
  """
  @spec render(Tymeslot.Emails.EmailService.user_map(), String.t()) :: Email.t()
  def render(user, booking_url) do
    RecipientLocale.with_user_locale(user, fn ->
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(dgettext("emails_account", "Your booking link"))
      |> Email.html_body(html_body(user, booking_url))
      |> Email.text_body(text_body(user, booking_url))
      |> Email.attachment(
        Attachment.new({:data, QrCode.png(booking_url)},
          filename: @qr_filename,
          cid: @qr_filename,
          content_type: "image/png",
          type: :inline
        )
      )
    end)
  end

  defp html_body(user, booking_url) do
    safe_url = Sanitise.sanitize_url(booking_url) || ""
    dashboard_url = UrlBuilder.build_url("/dashboard")

    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(dgettext("emails_account", "Here is your booking page. Send it to anyone who needs a time with you."), padding: "0 0 12px 0")}

    #{Text.centered_html(~s(<a href="#{safe_url}" style="color: #{Styles.component_color(:link)}; word-break: break-all;">#{safe_url}</a>), font_size: "20px", font_weight: "700", padding: "0 0 4px 0")}

    #{Buttons.action_button(@intent, dgettext("emails_account", "Open your page"), booking_url, full_width: true, size: :large)}

    #{Text.divider(margin: "20px 0 12px 0")}

    #{Text.centered_text(dgettext("emails_account", "Add it to your email signature"), font_weight: "700", padding: "0 0 4px 0")}

    #{Text.centered_text(signature_line(booking_url), padding: "0 0 12px 0")}

    <mj-section padding="8px 0 4px 0">
      <mj-column>
        <mj-image src="cid:#{@qr_filename}" alt="#{Sanitise.sanitize_for_email(dgettext("emails_account", "QR code for your booking page"))}" width="160px" padding="0" />
      </mj-column>
    </mj-section>

    #{Text.centered_html(~s(<a href="#{dashboard_url}" style="color: #{Styles.ink_muted()}; text-decoration: underline;">#{Sanitise.sanitize_for_email(dgettext("emails_account", "Manage your page"))}</a>), font_size: "13px", padding: "20px 0 0 0")}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_account", "Your booking link"),
      dgettext("emails_account", "Your booking page, ready to send to anyone."),
      intent: @intent,
      eyebrow: dgettext("emails_account", "Your page"),
      stage_title: dgettext("emails_account", "Your booking link")
    )
  end

  defp text_body(user, booking_url) do
    """
    #{Greeting.text(user)}

    #{dgettext("emails_account", "Here is your booking page. Send it to anyone who needs a time with you.")}

    #{booking_url}

    #{dgettext("emails_account", "Add it to your email signature")}
    #{signature_line(booking_url)}

    #{dgettext("emails_account", "Manage your page: %{url}", url: UrlBuilder.build_url("/dashboard"))}
    """
  end

  defp signature_line(booking_url),
    do: dgettext("emails_account", "Book a time with me: %{url}", url: booking_url)
end
