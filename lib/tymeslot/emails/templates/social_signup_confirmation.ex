defmodule Tymeslot.Emails.Templates.SocialSignupConfirmation do
  @moduledoc """
  Email template for the link that finishes a social sign-up with an address
  the user typed. The account is only created when the link is followed,
  which is what proves the address; see
  `Tymeslot.Auth.OAuth.SignupConfirmation`.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Buttons, Greeting, SignInProvider, TemplateHelper, Text}

  # A first-contact email welcoming a new user in.
  @intent :confirmed

  @spec render(Tymeslot.Emails.EmailService.user_map(), String.t(), String.t()) :: String.t()
  def render(recipient, provider, confirm_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(recipient), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(explanation(provider), padding: "0 0 20px 0")}

    #{Buttons.action_button(@intent, dgettext("emails", "Confirm Email & Finish Signing Up"), confirm_url, full_width: true, size: :large)}

    #{Text.system_footer_note(footer())}

    #{Text.divider(margin: "28px 0 16px 0")}

    #{Text.troubleshooting_link(confirm_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Account Verification"),
      dgettext("emails", "Confirm your email to finish signing up for Tymeslot."),
      intent: @intent,
      eyebrow: dgettext("emails", "Welcome"),
      stage_title: dgettext("emails", "One step to go"),
      stage_subtitle: dgettext("emails", "Confirm your email and your account is ready.")
    )
  end

  @spec render_text(Tymeslot.Emails.EmailService.user_map(), String.t(), String.t()) ::
          String.t()
  def render_text(recipient, provider, confirm_url) do
    """
    #{dgettext("emails", "One step to go")}

    #{Greeting.text(recipient)}

    #{explanation(provider)}

    #{dgettext("emails", "Confirm Email & Finish Signing Up:")}
    #{confirm_url}

    #{footer()}
    """
  end

  defp explanation(provider) do
    dgettext(
      "emails",
      "You're signing up for Tymeslot with %{provider}. Confirm this email address to create your account and sign in.",
      provider: SignInProvider.display_name(%{provider: provider})
    )
  end

  defp footer do
    dgettext(
      "emails",
      "This link expires in 24 hours. If you didn't sign up for Tymeslot, you can ignore this email and no account will be created."
    )
  end
end
