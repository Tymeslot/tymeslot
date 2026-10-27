defmodule Tymeslot.Integrations.Video.AccountCleanup do
  @moduledoc """
  Revokes the OAuth grants an account being deleted gave its video
  providers: Google Meet through Google's revoke endpoint, Zoom through
  Zoom's. Microsoft Teams has no practical per-token revoke, and MiroTalk or
  a custom link holds no grant, so those are left alone.

  A grant another account still relies on is not revoked (`GrantSharing`):
  Google's revoke ends the grant for every account on that Google account,
  calendars included, and Zoom's removes the app for the Zoom user, whose
  deauthorisation webhook would then disconnect every account linked to it.
  The deleted account's own rows still go with the account.

  Rooms are not deleted: a guest may still join a meeting that the deletion
  removes from Tymeslot, and deleting the room would break their link.

  Best-effort: a failure, including a raise or exit while cleaning one
  integration (a database error, a lock timeout, the HTTP client), is logged
  and the next integration is tried. A Google Meet row holding no token has
  no grant and is passed over quietly. Must run before the account row is
  deleted, which cascades the credentials away.
  """

  alias Tymeslot.Infrastructure.BestEffort
  alias Tymeslot.Integrations.Shared.OAuth.GoogleTokenRevocation
  alias Tymeslot.Integrations.Shared.OAuth.GrantSharing
  alias Tymeslot.Integrations.Video.AccessToken
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper

  @spec run(pos_integer()) :: :ok
  def run(user_id) do
    user_id
    |> VideoIntegrationQueries.list_all_for_user_including_disconnected()
    |> Enum.each(fn integration ->
      BestEffort.run(
        :revoke_grant,
        fn -> if GrantSharing.shared?(integration), do: :ok, else: clean_up(integration) end,
        "Account deletion: video grant revocation failed; carrying on",
        provider: integration.provider,
        integration_id: integration.id,
        user_id: integration.user_id
      )
    end)
  end

  # A credential that no longer decrypts reads as unset, which would pass for
  # a row holding no grant; it is a grant left unrevoked, so it is reported.
  defp clean_up(%{provider: "google_meet"} = integration) do
    case VideoIntegrationSchema.decryption_status(integration) do
      :ok -> GoogleTokenRevocation.revoke_grant(integration)
      :requires_reencryption -> {:error, :requires_reencryption}
    end
  end

  # Zoom revokes by access token, so an expired one is refreshed first,
  # through the provider, which takes the refresh lock and stores the result.
  defp clean_up(%{provider: "zoom"} = integration) do
    with {:ok, token} <- AccessToken.fetch(integration.id, integration.user_id) do
      ZoomOAuthHelper.revoke_token(token)
    end
  end

  defp clean_up(_integration), do: :ok
end
