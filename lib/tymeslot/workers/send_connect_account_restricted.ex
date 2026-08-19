defmodule Tymeslot.Workers.SendConnectAccountRestricted do
  @moduledoc """
  Sends the host email notifying them that Stripe has flagged their connected
  account as restricted.

  Enqueued from `Tymeslot.MeetingPayments.ConnectAccounts.apply_account_event/1`
  only on a transition into a different `disabled_reason` and only after the
  ordering check (`event.created` > `last_account_event_at`) has passed.

  Loads the row inside `perform/1` so the email reflects the committed
  account state, even if a follow-up event has already updated the row.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    priority: 0,
    unique: [
      keys: [:connect_account_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      period: 86_400
    ]

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Emails.Templates.ConnectAccountRestricted
  alias Tymeslot.Emails.Templates.ConnectAccountRestricted.RestrictionContext
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connect_account_id" => id} = args}) do
    case MeetingPayments.get_connect_account(id) do
      nil ->
        Logger.warning("Connect-restricted email skipped — connect_account not found",
          connect_account_id: id
        )

        {:discard, "connect_account not found"}

      %ConnectAccountSchema{user_id: nil} ->
        Logger.warning("Connect-restricted email skipped — connect_account has no user_id",
          connect_account_id: id
        )

        {:discard, "missing user_id"}

      %ConnectAccountSchema{} = account ->
        send_email(account, args)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("SendConnectAccountRestricted missing connect_account_id",
      args: inspect(args)
    )

    {:discard, "missing connect_account_id"}
  end

  defp send_email(account, args) do
    case UserQueries.get_user(account.user_id) do
      {:ok, %UserSchema{email: email} = user} when is_binary(email) and email != "" ->
        deliver(account, user, args)

      {:ok, _user} ->
        Logger.warning("Connect-restricted email skipped — user has no email",
          user_id: account.user_id
        )

        {:discard, "user has no email"}

      {:error, :not_found} ->
        Logger.warning("Connect-restricted email skipped — user not found",
          user_id: account.user_id
        )

        {:discard, "user not found"}
    end
  end

  defp deliver(account, user, args) do
    context = build_context(account, user, args)

    context
    |> ConnectAccountRestricted.render()
    |> TransactionalEmailDelivery.deliver("Connect-restricted email delivery failed",
      connect_account_id: account.id
    )
  end

  defp build_context(account, user, args) do
    %RestrictionContext{
      host_email: user.email,
      host_name: user_display_name(user),
      disabled_reason: account.disabled_reason || args["disabled_reason"],
      previous_disabled_reason: args["previous_disabled_reason"],
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      dashboard_url: args["dashboard_url"]
    }
  end

  defp user_display_name(%UserSchema{name: name}) when is_binary(name) and name != "",
    do: name

  defp user_display_name(_user), do: nil
end
