defmodule Tymeslot.Emails.EmailService.AccountEmails do
  @moduledoc "Account management emails: email change verification, notification, and confirmation."

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.MjmlEmail

  alias Tymeslot.Emails.Templates.{
    EmailChangeConfirmed,
    EmailChangeNotification,
    EmailChangeVerification
  }

  alias Swoosh.Email

  use Gettext, backend: TymeslotWeb.Gettext

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

    RecipientLocale.with_user_locale(user, fn ->
      html_body = EmailChangeVerification.render(user, new_email, verification_url)
      text_body = EmailChangeVerification.render_text(user, new_email, verification_url)

      MjmlEmail.base_email()
      |> Email.to({user.name || new_email, new_email})
      |> Email.subject(dgettext("emails", "Verify your new email address"))
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)
      |> Delivery.deliver()
    end)
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

    RecipientLocale.with_user_locale(user, fn ->
      html_body = EmailChangeNotification.render(user, new_email, request_time)
      text_body = EmailChangeNotification.render_text(user, new_email, request_time)

      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(dgettext("emails", "⚠️ Email Change Request - Security Alert"))
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)
      |> Delivery.deliver()
    end)
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

    {old_result, new_result} =
      RecipientLocale.with_user_locale(user, fn ->
        {deliver_confirmation(user, old_email, new_email, confirmed_time, true),
         deliver_confirmation(user, old_email, new_email, confirmed_time, false)}
      end)

    Logger.info("Email change confirmations sent",
      old_sent: match?({:ok, _}, old_result),
      new_sent: match?({:ok, _}, new_result)
    )

    {old_result, new_result}
  end

  # `is_old_email?` selects both the recipient and the wording: the old address
  # gets the "this switch happened" notice, the new one the welcome.
  defp deliver_confirmation(user, old_email, new_email, confirmed_time, is_old_email?) do
    {recipient, subject} =
      if is_old_email? do
        {old_email, dgettext("emails", "Email Address Changed - Tymeslot Account")}
      else
        {new_email, dgettext("emails", "Email Address Changed Successfully")}
      end

    MjmlEmail.base_email()
    |> Email.to({user.name || recipient, recipient})
    |> Email.subject(subject)
    |> Email.html_body(
      EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, is_old_email?)
    )
    |> Email.text_body(
      EmailChangeConfirmed.render_text(user, old_email, new_email, confirmed_time, is_old_email?)
    )
    |> Delivery.deliver()
  end
end
