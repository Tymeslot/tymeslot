defmodule Tymeslot.Integrations.Calendar.TokenRefreshJobRevokedGrantTest do
  @moduledoc """
  A revoked grant met by the scheduled refresh, end to end: the real Google
  calendar client against Google's token endpoint answering `invalid_grant`.

  The job must leave the integration exactly as a provider API call meeting
  the same refusal does through the health check: flagged for reconnection
  with the expired-grant reason, still active, and the owner emailed.
  """

  # async: false: the calendar API module and the Google OAuth credentials are
  # application-wide configuration.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    put_env(:google_calendar_api_module, CalendarAPI)
    put_env(:google_oauth, client_id: "google-id", client_secret: "google-secret")
    :ok
  end

  test "flags the integration for reconnection and emails the owner" do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        refresh_token_encrypted: Encryption.encrypt("revoked-refresh-token"),
        token_expires_at:
          DateTime.truncate(DateTime.add(DateTime.utc_now(), -60, :second), :second)
      )

    expect(Tymeslot.HTTPClientMock, :request, fn :post,
                                                 "https://oauth2.googleapis.com/token",
                                                 body,
                                                 _headers,
                                                 _opts ->
      assert URI.decode_query(body)["refresh_token"] == "revoked-refresh-token"
      {:ok, %Req.Response{status: 400, body: ~s({"error":"invalid_grant"})}}
    end)

    assert {:discard, reason} =
             perform_job(TokenRefreshJob, %{"integration_id" => integration.id})

    assert reason =~ "invalid_grant"

    updated = Repo.get!(CalendarIntegrationSchema, integration.id)
    assert updated.needs_reauth
    assert updated.is_active
    assert updated.sync_error == ReauthHandling.reauth_error_message(:expired_grant)

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_integration_reauth_notification",
        "user_id" => user.id,
        "integration_id" => integration.id,
        "integration_type" => "calendar"
      }
    )
  end

  defp put_env(key, value) do
    prior = Application.fetch_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, value)

    on_exit(fn ->
      case prior do
        {:ok, prior_value} -> Application.put_env(:tymeslot, key, prior_value)
        :error -> Application.delete_env(:tymeslot, key)
      end
    end)
  end
end
