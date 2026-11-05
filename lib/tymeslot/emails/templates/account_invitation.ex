defmodule Tymeslot.Emails.Templates.AccountInvitation do
  @moduledoc """
  Email template for the invitation an admin sends to a new account: the
  link lets the invitee choose how they will sign in, and signs them in.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{Buttons, Greeting, MjmlEmail, TemplateHelper, Text}

  # A welcome: an account is ready and waiting for its owner.
  @intent :confirmed

  @doc """
  The email, addressed and rendered in the recipient's locale.
  """
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          String.t()
        ) :: Email.t()
  def render(user, invitation_url) do
    RecipientLocale.with_user_locale(user, fn ->
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(dgettext("emails_account", "You're invited to Tymeslot"))
      |> Email.html_body(html_body(user, invitation_url))
      |> Email.text_body(text_body(user, invitation_url))
    end)
  end

  defp html_body(user, invitation_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(dgettext("emails_account", "An administrator has created a Tymeslot account for you. Accept the invitation to choose how you'll sign in and set up your booking page."), padding: "0 0 20px 0")}

    #{Buttons.action_button(@intent, dgettext("emails_account", "Accept invitation"), invitation_url, full_width: true, size: :large)}

    #{Text.system_footer_note(dgettext("emails_account", "This link is valid for 7 days."))}
    #{Text.system_footer_note(dgettext("emails_account", "If you weren't expecting this invitation, you can ignore this email."))}

    #{Text.divider(margin: "28px 0 16px 0")}

    #{Text.troubleshooting_link(invitation_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_account", "Invitation"),
      dgettext(
        "emails_account",
        "Your Tymeslot account is ready. Accept the invitation to sign in."
      ),
      intent: @intent,
      eyebrow: dgettext("emails_account", "Invitation"),
      stage_title: dgettext("emails_account", "You're invited to Tymeslot"),
      stage_subtitle: dgettext("emails_account", "Your account is ready and waiting.")
    )
  end

  defp text_body(user, invitation_url) do
    """
    #{dgettext("emails_account", "You're invited to Tymeslot")}

    #{Greeting.text(user)}

    #{dgettext("emails_account", "An administrator has created a Tymeslot account for you. Accept the invitation to choose how you'll sign in and set up your booking page.")}

    #{dgettext("emails_account", "Accept invitation:")}
    #{invitation_url}

    #{dgettext("emails_account", "This link is valid for 7 days.")}

    #{dgettext("emails_account", "If you weren't expecting this invitation, you can ignore this email.")}
    """
  end
end
