defmodule Tymeslot.Emails.Templates.SignupAttemptNotice do
  @moduledoc """
  Email template sent to an account's owner when someone tries to sign up with
  their address.

  The sign-up form answers a registered address exactly as it answers a new
  one, so this email is where the owner, if it was them, learns that they
  already have an account and how to get back into it.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Greeting,
    Sanitise,
    SignInProvider,
    Styles,
    TemplateHelper,
    Text
  }

  # Account security information about an attempt the owner may not have made.
  @intent :alert

  @spec render(Tymeslot.Emails.EmailService.user_map(), String.t(), String.t()) :: String.t()
  def render(user, sign_in_url, reset_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(explanation(user), padding: "0 0 20px 0")}

    #{Buttons.action_button(@intent, dgettext("emails", "Sign In to Tymeslot"), sign_in_url, full_width: true, size: :large)}

    #{reset_section(user, reset_url)}

    #{Text.system_footer_note(dgettext("emails", "If it wasn't you, you can ignore this email. No new account was created and nothing about your account has changed."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Account Security"),
      dgettext("emails", "Someone tried to sign up with your email address."),
      intent: @intent,
      eyebrow: dgettext("emails", "Security"),
      stage_title: dgettext("emails", "You already have an account"),
      stage_subtitle: dgettext("emails", "Sign in instead of signing up.")
    )
  end

  @spec render_text(Tymeslot.Emails.EmailService.user_map(), String.t(), String.t()) ::
          String.t()
  def render_text(user, sign_in_url, reset_url) do
    """
    #{dgettext("emails", "You already have an account")}

    #{Greeting.text(user)}

    #{explanation(user)}

    #{dgettext("emails", "Sign In to Tymeslot:")}
    #{sign_in_url}
    #{reset_text(user, reset_url)}
    #{dgettext("emails", "If it wasn't you, you can ignore this email. No new account was created and nothing about your account has changed.")}
    """
  end

  # An account that signs in through a provider has no password to reset, so
  # it is pointed at the provider instead of at the reset form.
  defp explanation(user) do
    if SignInProvider.social?(user) do
      dgettext(
        "emails",
        "Someone just tried to create a new Tymeslot account with this email address, which already has an account. If it was you, sign in with %{provider} below.",
        provider: SignInProvider.display_name(user)
      )
    else
      dgettext(
        "emails",
        "Someone just tried to create a new Tymeslot account with this email address, which already has an account. If it was you, sign in below, or reset your password if you can't remember it."
      )
    end
  end

  defp reset_section(user, reset_url) do
    if SignInProvider.social?(user),
      do: "",
      else: Text.centered_html(reset_link(reset_url), padding: "4px 0 0 0")
  end

  defp reset_text(user, reset_url) do
    if SignInProvider.social?(user) do
      ""
    else
      """

      #{dgettext("emails", "Reset your password:")}
      #{reset_url}
      """
    end
  end

  # A secondary, text-weight link under the one button, so the email keeps a
  # single primary action.
  defp reset_link(reset_url) do
    safe_url = Sanitise.sanitize_url(reset_url)

    safe_label =
      Sanitise.sanitize_for_email(dgettext("emails", "Forgot your password? Reset it here."))

    ~s(<a href="#{safe_url}" style="color: #{Styles.component_color(:link)}; text-decoration: underline;">#{safe_label}</a>)
  end
end
