defmodule Tymeslot.Emails.Templates.SocialSignupConfirmation do
  @moduledoc """
  Email template for the link that finishes a social sign-up with an address
  the user typed. The account is only created when the link is followed,
  which is what proves the address; see
  `Tymeslot.Auth.OAuth.SignupConfirmation`.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Greeting,
    MjmlEmail,
    SignInProvider,
    TemplateHelper,
    Text
  }

  # A first-contact email welcoming a new user in.
  @intent :confirmed

  @doc """
  The email, addressed and rendered in the recipient's locale.
  """
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t()
        ) :: Email.t()
  def render(recipient, provider, confirm_url) do
    RecipientLocale.with_user_locale(recipient, fn ->
      MjmlEmail.base_email()
      |> Email.to({recipient.name || recipient.email, recipient.email})
      |> Email.subject(dgettext("emails_account", "Confirm your email to finish signing up"))
      |> Email.html_body(html_body(recipient, provider, confirm_url))
      |> Email.text_body(text_body(recipient, provider, confirm_url))
    end)
  end

  defp html_body(recipient, provider, confirm_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(recipient), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(explanation(provider), padding: "0 0 20px 0")}

    #{Buttons.action_button(@intent, dgettext("emails_account", "Confirm Email & Finish Signing Up"), confirm_url, full_width: true, size: :large)}

    #{Text.system_footer_note(footer())}

    #{Text.divider(margin: "28px 0 16px 0")}

    #{Text.troubleshooting_link(confirm_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_account", "Account Verification"),
      dgettext("emails_account", "Confirm your email to finish signing up for Tymeslot."),
      intent: @intent,
      eyebrow: dgettext("emails_account", "Welcome"),
      stage_title: dgettext("emails_account", "One step to go"),
      stage_subtitle: dgettext("emails_account", "Confirm your email and your account is ready.")
    )
  end

  defp text_body(recipient, provider, confirm_url) do
    """
    #{dgettext("emails_account", "One step to go")}

    #{Greeting.text(recipient)}

    #{explanation(provider)}

    #{dgettext("emails_account", "Confirm Email & Finish Signing Up:")}
    #{confirm_url}

    #{footer()}
    """
  end

  defp explanation(provider) do
    dgettext(
      "emails_account",
      "You're signing up for Tymeslot with %{provider}. Confirm this email address to create your account and sign in.",
      provider: SignInProvider.display_name(%{provider: provider})
    )
  end

  defp footer do
    dgettext(
      "emails_account",
      "This link expires in 24 hours. If you didn't sign up for Tymeslot, you can ignore this email and no account will be created."
    )
  end
end
