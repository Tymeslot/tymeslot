defmodule Tymeslot.Slack.AccountCleanup do
  @moduledoc """
  Revokes the bot token of every Slack workspace a user connected, for an
  account being deleted. Webhook-only integrations hold no token and are
  skipped. Best-effort and independent per integration: one that cannot be
  read or revoked is logged and the rest are still handled.

  Slack issues one bot token per workspace for the app, so a workspace that
  another account has also connected keeps its token: revoking it would cut
  that account's integration off too. Only the last account to leave a
  workspace revokes it; the deleted account's copy goes with its rows.
  """

  alias Tymeslot.Infrastructure.BestEffort
  alias Tymeslot.Slack.{API, SlackIntegrationSchema, SlackQueries}

  @spec run(integer()) :: :ok
  def run(user_id) do
    user_id
    |> SlackQueries.list_integrations()
    |> Enum.reject(&workspace_shared?/1)
    |> Enum.each(&revoke_token/1)
  end

  defp workspace_shared?(%SlackIntegrationSchema{team_id: team_id, user_id: user_id})
       when is_binary(team_id),
       do: SlackQueries.workspace_token_shared?(team_id, user_id)

  defp workspace_shared?(_no_workspace), do: false

  defp revoke_token(%SlackIntegrationSchema{} = integration) do
    BestEffort.run(
      :revoke_token,
      fn ->
        with token when is_binary(token) <- SlackIntegrationSchema.bot_token(integration) do
          API.revoke_token(token)
        end
      end,
      "Account deletion: Slack token revocation failed; carrying on",
      integration_id: integration.id,
      user_id: integration.user_id
    )
  end
end
