defmodule Tymeslot.Emails.EmailService.AccountEmails do
  @moduledoc "Account management emails: email change verification, notification, and confirmation."

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.Shared.MjmlEmail

  alias Tymeslot.Emails.Templates.{
    EmailChangeConfirmed,
    EmailChangeNotification,
    EmailChangeVerification
  }

  alias Swoosh.Email

  @doc """
  Sends an email change verification email to the NEW email address.
  """
  @spec send_email_change_verification(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_email_change_verification(user, new_email, verification_url) do
    Logger.info("Sending email change verification",
      user_id: user.id,
      new_email: new_email
    )

    html_body = EmailChangeVerification.render(user, new_email, verification_url)
    text_body = EmailChangeVerification.render_text(user, new_email, verification_url)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || new_email, new_email})
      |> Email.subject("Verify your new email address")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Sends an email change notification to the OLD email address.
  """
  @spec send_email_change_notification(Tymeslot.Emails.EmailService.user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_email_change_notification(user, new_email) do
    Logger.info("Sending email change notification",
      user_id: user.id,
      old_email: user.email,
      new_email: new_email
    )

    request_time = DateTime.utc_now()
    html_body = EmailChangeNotification.render(user, new_email, request_time)
    text_body = EmailChangeNotification.render_text(user, new_email, request_time)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject("⚠️ Email Change Request - Security Alert")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Sends email change confirmation to both OLD and NEW email addresses.
  """
  @spec send_email_change_confirmations(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t()
        ) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_email_change_confirmations(user, old_email, new_email) do
    Logger.info("Sending email change confirmations",
      user_id: user.id,
      old_email: old_email,
      new_email: new_email
    )

    confirmed_time = DateTime.utc_now()

    html_body_old = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, true)

    text_body_old =
      EmailChangeConfirmed.render_text(user, old_email, new_email, confirmed_time, true)

    email_old =
      MjmlEmail.base_email()
      |> Email.to({user.name || old_email, old_email})
      |> Email.subject("Email Address Changed - Tymeslot Account")
      |> Email.html_body(html_body_old)
      |> Email.text_body(text_body_old)

    old_result = Delivery.deliver(email_old)

    html_body_new = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, false)

    text_body_new =
      EmailChangeConfirmed.render_text(user, old_email, new_email, confirmed_time, false)

    email_new =
      MjmlEmail.base_email()
      |> Email.to({user.name || new_email, new_email})
      |> Email.subject("Email Address Changed Successfully")
      |> Email.html_body(html_body_new)
      |> Email.text_body(text_body_new)

    new_result = Delivery.deliver(email_new)

    Logger.info("Email change confirmations sent",
      old_sent: match?({:ok, _}, old_result),
      new_sent: match?({:ok, _}, new_result)
    )

    {old_result, new_result}
  end
end
