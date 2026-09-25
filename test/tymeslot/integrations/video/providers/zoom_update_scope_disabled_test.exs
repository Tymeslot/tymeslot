defmodule Tymeslot.Integrations.Video.Providers.ZoomUpdateScopeDisabledTest do
  @moduledoc """
  Covers the deployment whose Zoom app is *not* configured for
  `meeting:update:meeting` and opts out with `ZOOM_UPDATE_SCOPE_ENABLED=false`.

  Every other Zoom test runs with the scope enabled, which is the default. This
  module drives the other side of that switch: once the scope is unobtainable,
  no grant can hold it, so a reconnect prompt would send the account owner
  round a loop that cannot end. The gap belongs to the operator instead.
  """

  # Not async: `:zoom_update_scope_enabled` is application-wide.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.ZoomScopeAuditWorker
  alias Tymeslot.ZoomOAuthHelperMock

  # Everything a deployment without the update scope asks Zoom for.
  @requested_grant "meeting:write:meeting meeting:delete:meeting meeting:read:meeting user:read:user"

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:tymeslot, :zoom_update_scope_enabled, true)
    original_oauth = Application.get_env(:tymeslot, :zoom_oauth)

    Application.put_env(:tymeslot, :zoom_update_scope_enabled, false)

    Application.put_env(:tymeslot, :zoom_oauth,
      client_id: "zoom-client-id",
      client_secret: "zoom-client-secret",
      state_secret: "zoom-state-secret"
    )

    on_exit(fn ->
      Application.put_env(:tymeslot, :zoom_update_scope_enabled, previous)

      if is_nil(original_oauth) do
        Application.delete_env(:tymeslot, :zoom_oauth)
      else
        Application.put_env(:tymeslot, :zoom_oauth, original_oauth)
      end
    end)

    :ok
  end

  describe "with the update scope disabled" do
    test "does not ask Zoom for meeting:update:meeting" do
      refute Scopes.requestable?(:update)
      refute Scopes.requested_scope() =~ "meeting:update:meeting"
      assert Scopes.requested_operations() == [:write, :delete]
    end

    test "leaves the scope out of the authorization URL" do
      url = ZoomOAuthHelper.authorization_url(123, "https://example.com/cb")
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["scope"] =~ "meeting:delete:meeting"
      refute query["scope"] =~ "meeting:update:meeting"
    end

    test "refuses the reschedule without asking the owner to reconnect" do
      %{integration: integration, config: config} = zoom_config(@requested_grant)

      # No HTTP expectation: the pre-flight must short-circuit before any call.
      assert {:error, :insufficient_scope} =
               ZoomProvider.update_meeting_room("123456789", config)

      {:ok, reloaded} = VideoIntegrationQueries.get(integration.id)
      refute reloaded.needs_reauth
    end

    test "does not ask the owner to reconnect when Zoom rejects the PATCH with 4711" do
      %{integration: integration, config: config} =
        zoom_config("meeting:write:meeting meeting:update:meeting")

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => 4711,
               "message" =>
                 "Invalid access token, does not contain scopes:[meeting:update:meeting]."
             })
         }}
      end)

      assert {:error, :insufficient_scope} =
               ZoomProvider.update_meeting_room("123456789", config)

      {:ok, reloaded} = VideoIntegrationQueries.get(integration.id)
      refute reloaded.needs_reauth
    end

    test "the audit leaves a grant holding every requested scope alone" do
      integration = zoom_integration(oauth_scope: @requested_grant)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute Repo.reload!(integration).needs_reauth
      refute_enqueued(worker: EmailWorker)
    end

    test "the audit reports the blocked integrations so the gap is not silent" do
      zoom_integration(oauth_scope: @requested_grant)

      log =
        capture_log(fn ->
          assert :ok = perform_job(ZoomScopeAuditWorker, %{})
        end)

      assert log =~ "users cannot fix this by reconnecting"
    end

    test "the audit still flags a stale grant that is also short the update scope" do
      # Short of the delete scope, which reconnecting restores. The gap the user
      # can close must not be masked by the one they cannot.
      integration =
        zoom_integration(oauth_scope: "meeting:write:meeting meeting:read:meeting user:read:user")

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth
      assert reloaded.sync_error =~ "cancel meetings"
    end
  end

  defp zoom_integration(attrs) do
    insert(:video_integration, [provider: "zoom", name: "Zoom"] ++ attrs)
  end

  defp zoom_config(oauth_scope) do
    user = insert(:user)
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, integration} =
      VideoIntegrationQueries.create(%{
        user_id: user.id,
        name: "Zoom",
        provider: "zoom",
        access_token: "valid_token",
        refresh_token: "valid_refresh",
        token_expires_at: expires_at,
        oauth_scope: oauth_scope
      })

    config = %{
      access_token: "valid_token",
      refresh_token: "valid_refresh",
      token_expires_at: expires_at,
      oauth_scope: oauth_scope,
      integration_id: integration.id,
      user_id: user.id,
      meeting_topic: "Test Meeting",
      meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
      meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
    }

    %{integration: integration, config: config}
  end
end
