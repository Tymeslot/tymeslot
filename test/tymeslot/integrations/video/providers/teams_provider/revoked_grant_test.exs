defmodule Tymeslot.Integrations.Video.Providers.TeamsProvider.RevokedGrantTest do
  @moduledoc """
  A Teams grant refused for good while refreshing is the owner's to fix: the
  integration is flagged, which emails the owner, and room creation fails as
  unauthorised, the reason it treats as final, instead of as provider text it
  would retry as an outage.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations
  @moduletag :video

  import Mox

  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.TeamsOAuthHelperMock
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  test "a refresh refused with invalid_grant flags the integration and fails as unauthorised" do
    user = insert(:user)
    expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

    {:ok, integration} =
      VideoIntegrationQueries.create(%{
        user_id: user.id,
        name: "Teams",
        provider: "teams",
        tenant_id: "t1",
        teams_user_id: "u1",
        access_token: "expired",
        refresh_token: "refresh",
        token_expires_at: expired_at,
        oauth_scope: "Calendars.ReadWrite"
      })

    config = %{
      access_token: "expired",
      refresh_token: "refresh",
      token_expires_at: expired_at,
      integration_id: integration.id,
      user_id: user.id,
      oauth_scope: "Calendars.ReadWrite",
      event_details: %EventDetails{
        summary: "Quarterly review",
        start_time: ~U[2030-03-14 09:30:00Z],
        end_time: ~U[2030-03-14 10:15:00Z]
      }
    }

    expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :needs_refresh} end)

    expect(TeamsOAuthHelperMock, :refresh_access_token, fn "refresh", _scope, _opts ->
      {:error, "Token refresh failed: invalid_grant"}
    end)

    assert {:error, :unauthorized} = ProviderAdapter.create_meeting_room(:teams, config)
    assert Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_integration_reauth_notification",
        "integration_id" => integration.id
      }
    )
  end
end
