defmodule Tymeslot.Emails.Templates.SignupAttemptNotice do
  @moduledoc """
  Email template sent to an account's owner when someone tries to sign up with
  their address.

  The sign-up form answers a registered address exactly as it answers a new
  one, so this email is where the owner, if it was them, learns that they
  already have an account and how to get back into it. For an account pending
  deletion the explanation names the deletion date instead.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Auth.AccountDeletion.Policy

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    Greeting,
    MjmlEmail,
    Sanitise,
    SignInProvider,
    Styles,
    TemplateHelper,
    Text
  }

  # Account security information about an attempt the owner may not have made.
  @intent :alert

  @doc """
  The email, addressed and rendered in the recipient's locale.
  """
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t()
        ) :: Email.t()
  def render(user, sign_in_url, reset_url) do
    RecipientLocale.with_user_locale(user, fn ->
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(dgettext("emails_account", "You already have a Tymeslot account"))
      |> Email.html_body(html_body(user, sign_in_url, reset_url))
      |> Email.text_body(text_body(user, sign_in_url, reset_url))
    end)
  end

  defp html_body(user, sign_in_url, reset_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(explanation(user), padding: "0 0 20px 0")}

    #{Buttons.action_button(@intent, dgettext("emails_account", "Sign In to Tymeslot"), sign_in_url, full_width: true, size: :large)}

    #{reset_section(user, reset_url)}

    #{Text.system_footer_note(dgettext("emails_account", "If it wasn't you, you can ignore this email. No new account was created and nothing about your account has changed."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_account", "Account Security"),
      dgettext("emails_account", "Someone tried to sign up with your email address."),
      intent: @intent,
      eyebrow: dgettext("emails_account", "Security"),
      stage_title: dgettext("emails_account", "You already have an account"),
      stage_subtitle: dgettext("emails_account", "Sign in instead of signing up.")
    )
  end

  defp text_body(user, sign_in_url, reset_url) do
    """
    #{dgettext("emails_account", "You already have an account")}

    #{Greeting.text(user)}

    #{explanation(user)}

    #{dgettext("emails_account", "Sign In to Tymeslot:")}
    #{sign_in_url}
    #{reset_text(user, reset_url)}
    #{dgettext("emails_account", "If it wasn't you, you can ignore this email. No new account was created and nothing about your account has changed.")}
    """
  end

  # The address belongs to an account waiting to be deleted: the owner can
  # still restore it, or sign up afresh once it is gone.
  defp explanation(%{deletion_scheduled_at: %DateTime{} = at} = user) do
    dgettext(
      "emails_account",
      "Someone just tried to create a new Tymeslot account with this email address. It belongs to an account that is scheduled for deletion on %{date}. If it was you, sign in before then to restore that account, or sign up again after that date.",
      date:
        at
        |> Policy.user_local_date(user.id)
        |> Formatting.format_date(Gettext.get_locale(TymeslotWeb.Gettext))
    )
  end

  # An account that signs in through a provider has no password to reset, so
  # it is pointed at the provider instead of at the reset form.
  defp explanation(user) do
    if SignInProvider.social?(user) do
      dgettext(
        "emails_account",
        "Someone just tried to create a new Tymeslot account with this email address, which already has an account. If it was you, sign in with %{provider} below.",
        provider: SignInProvider.display_name(user)
      )
    else
      dgettext(
        "emails_account",
        "Someone just tried to create a new Tymeslot account with this email address, which already has an account. If it was you, sign in below, or reset your password if you can't remember it."
      )
    end
  end

  defp reset_section(user, reset_url) do
    case {SignInProvider.social?(user), Sanitise.sanitize_url(reset_url)} do
      {false, safe_url} when is_binary(safe_url) ->
        Text.centered_html(reset_link(safe_url), padding: "4px 0 0 0")

      _no_link ->
        ""
    end
  end

  defp reset_text(user, reset_url) do
    if SignInProvider.social?(user) do
      ""
    else
      """

      #{dgettext("emails_account", "Reset your password:")}
      #{reset_url}
      """
    end
  end

  # A secondary, text-weight link under the one button, so the email keeps a
  # single primary action.
  defp reset_link(safe_url) do
    safe_label =
      Sanitise.sanitize_for_email(
        dgettext("emails_account", "Forgot your password? Reset it here.")
      )

    ~s(<a href="#{safe_url}" style="color: #{Styles.component_color(:link)}; text-decoration: underline;">#{safe_label}</a>)
  end
end
