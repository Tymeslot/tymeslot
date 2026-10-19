defmodule Tymeslot.Emails.Templates.NoPasswordToReset do
  @moduledoc """
  Email template sent when a password reset is requested for an account that
  signs in through a provider (Google, GitHub or single sign-on) and so has no
  password to reset.

  The reset form answers every address the same way, so this email is the only
  place the owner learns why no reset link arrived and how they do sign in.
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

  # Account security information, but nothing has changed and nothing is wrong.
  @intent :alert

  @doc """
  The email, addressed and rendered in the recipient's locale.
  """
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          String.t()
        ) :: Email.t()
  def render(user, sign_in_url) do
    RecipientLocale.with_user_locale(user, fn ->
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(dgettext("emails_account", "Your Tymeslot account has no password"))
      |> Email.html_body(html_body(user, sign_in_url))
      |> Email.text_body(text_body(user, sign_in_url))
    end)
  end

  defp html_body(user, sign_in_url) do
    provider = SignInProvider.display_name(user)

    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(explanation(provider), padding: "0 0 20px 0")}

    #{Buttons.action_button(@intent, dgettext("emails_account", "Sign In to Tymeslot"), sign_in_url, full_width: true, size: :large)}

    #{Text.system_footer_note(dgettext("emails_account", "If you didn't ask to reset your password, you can ignore this email. Nothing about your account has changed."))}

    #{Text.divider(margin: "28px 0 16px 0")}

    #{Text.troubleshooting_link(sign_in_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_account", "Account Security"),
      dgettext("emails_account", "Your Tymeslot account has no password to reset."),
      intent: @intent,
      eyebrow: dgettext("emails_account", "Security"),
      stage_title: dgettext("emails_account", "No password to reset"),
      stage_subtitle:
        dgettext("emails_account", "You sign in with %{provider}.", provider: provider)
    )
  end

  defp text_body(user, sign_in_url) do
    provider = SignInProvider.display_name(user)

    """
    #{dgettext("emails_account", "No password to reset")}

    #{Greeting.text(user)}

    #{explanation(provider)}

    #{dgettext("emails_account", "Sign In to Tymeslot:")}
    #{sign_in_url}

    #{dgettext("emails_account", "If you didn't ask to reset your password, you can ignore this email. Nothing about your account has changed.")}
    """
  end

  defp explanation(provider) do
    dgettext(
      "emails_account",
      "Someone asked to reset the password for your Tymeslot account, but your account signs in with %{provider}, so it has no password to reset. Use the button below and choose %{provider} to sign in.",
      provider: provider
    )
  end
end
