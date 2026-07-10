defmodule Tymeslot.Emails.EmailService.AuthEmails do
  @moduledoc "Authentication emails: email verification and password reset."

  require Logger

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.MjmlEmail
  alias Tymeslot.Emails.Templates.{EmailVerification, PasswordReset}

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
end
