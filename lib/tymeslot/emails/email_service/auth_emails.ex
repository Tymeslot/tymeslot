defmodule Tymeslot.Emails.EmailService.AuthEmails do
  @moduledoc """
  Authentication emails: email verification, password reset, and the account
  notices sent instead of an on-screen answer.
  """

  require Logger

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.MjmlEmail

  alias Tymeslot.Emails.Templates.{
    EmailVerification,
    NoPasswordToReset,
    PasswordReset,
    SignupAttemptNotice
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Sends an email verification email to a new user.
  """
  @spec send_email_verification(Tymeslot.Emails.EmailService.user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_email_verification(user, verification_url) do
    Logger.info("Sending email verification", user_id: user.id)

    RecipientLocale.with_user_locale(user, fn ->
      html_body = EmailVerification.render(user, verification_url)
      text_body = EmailVerification.render_text(user, verification_url)

      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(dgettext("emails", "Verify your email address"))
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)
      |> Delivery.deliver()
    end)
  end

  @doc """
  Sends a password reset email to a user.
  """
  @spec send_password_reset(Tymeslot.Emails.EmailService.user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_password_reset(user, reset_url) do
    Logger.info("Sending password reset email", user_id: user.id)

    RecipientLocale.with_user_locale(user, fn ->
      html_body = PasswordReset.render(user, reset_url)
      text_body = PasswordReset.render_text(user, reset_url)

      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(dgettext("emails", "Reset your password"))
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)
      |> Delivery.deliver()
    end)
  end

  @doc """
  Tells an account that signs in through a provider that it has no password
  to reset, with a link to sign in.
  """
  @spec send_no_password_to_reset(Tymeslot.Emails.EmailService.user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_no_password_to_reset(user, sign_in_url) do
    Logger.info("Sending no-password-to-reset notice", user_id: user.id)

    deliver_to(user, fn ->
      {dgettext("emails", "Your Tymeslot account has no password"),
       NoPasswordToReset.render(user, sign_in_url),
       NoPasswordToReset.render_text(user, sign_in_url)}
    end)
  end

  @doc """
  Tells an account's owner that someone tried to sign up with their address,
  with links to sign in and to reset the password.
  """
  @spec send_signup_attempt_notice(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t()
        ) :: {:ok, any()} | {:error, any()}
  def send_signup_attempt_notice(user, sign_in_url, reset_url) do
    Logger.info("Sending sign-up attempt notice", user_id: user.id)

    deliver_to(user, fn ->
      {dgettext("emails", "You already have a Tymeslot account"),
       SignupAttemptNotice.render(user, sign_in_url, reset_url),
       SignupAttemptNotice.render_text(user, sign_in_url, reset_url)}
    end)
  end

  # `build` runs inside the recipient's locale, so the subject is translated
  # along with the bodies.
  defp deliver_to(user, build) do
    RecipientLocale.with_user_locale(user, fn ->
      {subject, html_body, text_body} = build.()

      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(subject)
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)
      |> Delivery.deliver()
    end)
  end
end
