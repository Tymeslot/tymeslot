defmodule Tymeslot.Emails.EmailService.AuthEmails do
  @moduledoc """
  Authentication emails: email verification, password reset, and the account
  notices sent instead of an on-screen answer. Each template builds its own
  email; this module delivers it.
  """

  require Logger

  alias Tymeslot.Emails.Delivery

  alias Tymeslot.Emails.Templates.{
    AccountDeletionNotice,
    EmailVerification,
    NoPasswordToReset,
    PasswordReset,
    SignupAttemptNotice,
    SocialSignupConfirmation
  }

  @doc """
  Sends an email verification email to a new user.
  """
  @spec send_email_verification(Tymeslot.Emails.EmailService.user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_email_verification(user, verification_url) do
    Logger.info("Sending email verification", user_id: user.id)

    user |> EmailVerification.render(verification_url) |> Delivery.deliver()
  end

  @doc """
  Sends a password reset email to a user.
  """
  @spec send_password_reset(Tymeslot.Emails.EmailService.user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_password_reset(user, reset_url) do
    Logger.info("Sending password reset email", user_id: user.id)

    user |> PasswordReset.render(reset_url) |> Delivery.deliver()
  end

  @doc """
  Tells an account that signs in through a provider that it has no password
  to reset, with a link to sign in.
  """
  @spec send_no_password_to_reset(Tymeslot.Emails.EmailService.user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_no_password_to_reset(user, sign_in_url) do
    Logger.info("Sending no-password-to-reset notice", user_id: user.id)

    user |> NoPasswordToReset.render(sign_in_url) |> Delivery.deliver()
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

    user |> SignupAttemptNotice.render(sign_in_url, reset_url) |> Delivery.deliver()
  end

  @doc """
  Tells an account's owner that the deletion they asked for is scheduled
  (`sign_in_url` given, so they can still restore it) or done (`nil`). The
  account may be gone by the time this is sent, so `recipient` is a plain map
  (address, name, locale), not the user.
  """
  @spec send_account_deletion_notice(
          Tymeslot.Emails.EmailService.user_map(),
          DateTime.t(),
          String.t() | nil
        ) :: {:ok, any()} | {:error, any()}
  def send_account_deletion_notice(recipient, scheduled_at, sign_in_url) do
    Logger.info("Sending account deletion notice")

    recipient |> AccountDeletionNotice.render(scheduled_at, sign_in_url) |> Delivery.deliver()
  end

  @doc """
  Sends the link that finishes a social sign-up with a typed address. There
  is no account yet: `recipient` is the typed address, the name the provider
  gave, and the locale the form was filled in.
  """
  @spec send_social_signup_confirmation(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t()
        ) :: {:ok, any()} | {:error, any()}
  def send_social_signup_confirmation(recipient, provider, confirm_url) do
    Logger.info("Sending sign-up confirmation")

    recipient |> SocialSignupConfirmation.render(provider, confirm_url) |> Delivery.deliver()
  end
end
