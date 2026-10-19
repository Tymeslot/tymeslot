defmodule Tymeslot.Integrations.Calendar.AccountCleanup do
  @moduledoc """
  Tells Google and Microsoft to stop working for an account that is being
  deleted, for every calendar it connected:

    * Google: stops the push channel, then revokes the OAuth grant, unless
      another account still holds a calendar or Google Meet on the same
      Google account (`GrantSharing`): the revoke would end its grant too.
    * Outlook: deletes the Graph change-notification subscription. Microsoft
      offers no practical per-token revoke for this flow; the grant becomes
      unusable once the stored refresh token is deleted with the account.

  Calendar events are not touched: a meeting the deletion removes from
  Tymeslot may still take place between host and guest, so the host's
  events stay where they are.

  Every step is best-effort: a failure is logged and the next step runs. Each
  integration is independent: credentials are decrypted per integration, and
  a raise or exit while cleaning one (an undecryptable row, a database error,
  a lock timeout) is logged without stopping the others. Must run before the
  account row is deleted, which cascades the credentials away.
  """

  alias Tymeslot.Infrastructure.BestEffort
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.PushChannel
  alias Tymeslot.Integrations.Calendar.Outlook.GraphSubscription
  alias Tymeslot.Integrations.Shared.OAuth.GoogleTokenRevocation
  alias Tymeslot.Integrations.Shared.OAuth.GrantSharing

  @spec run(pos_integer()) :: :ok
  def run(user_id) do
    user_id
    |> CalendarIntegrationQueries.list_all_for_user_encrypted()
    |> Enum.each(&clean_up_independently/1)
  end

  defp clean_up_independently(integration) do
    step(integration, :clean_up, fn ->
      integration
      |> CalendarIntegrationSchema.decrypt_credentials()
      |> clean_up()
    end)
  end

  # Stopping the channel and deleting the subscription always answer `:ok`
  # and log their own failures; each step is still isolated, so a raise in
  # one does not skip the next.
  defp clean_up(%CalendarIntegrationSchema{provider: "google"} = integration) do
    step(integration, :stop_push_channel, fn -> PushChannel.stop_push_channel(integration) end)
    step(integration, :revoke_grant, fn -> revoke_unless_shared(integration) end)
  end

  defp clean_up(%CalendarIntegrationSchema{provider: "outlook"} = integration),
    do:
      step(integration, :delete_graph_subscription, fn ->
        GraphSubscription.unregister(integration)
      end)

  defp clean_up(_integration), do: :ok

  defp revoke_unless_shared(integration) do
    if GrantSharing.shared?(integration),
      do: :ok,
      else: GoogleTokenRevocation.revoke_grant(integration)
  end

  defp step(integration, name, fun) do
    BestEffort.run(name, fun, "Account deletion: calendar cleanup step failed; carrying on",
      integration_id: integration.id,
      user_id: integration.user_id
    )
  end
end
