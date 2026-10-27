defmodule Tymeslot.Emails.EmailService.AccountEmails do
  @moduledoc """
  Account management emails: email change verification, notification, and
  confirmation. Each template builds its own email; this module delivers it.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Emails.Delivery

  alias Tymeslot.Emails.Templates.{
    EmailChangeConfirmed,
    EmailChangeNotification,
    EmailChangeVerification
  }

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

    user
    |> EmailChangeVerification.render(new_email, verification_url)
    |> Delivery.deliver()
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

    user
    |> EmailChangeNotification.render(new_email, Clock.utc_now())
    |> Delivery.deliver()
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

    confirmed_time = Clock.utc_now()

    [old_result, new_result] =
      for role <- [:old, :new] do
        role
        |> EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time)
        |> Delivery.deliver()
      end

    Logger.info("Email change confirmations sent",
      old_sent: match?({:ok, _}, old_result),
      new_sent: match?({:ok, _}, new_result)
    )

    {old_result, new_result}
  end
end
