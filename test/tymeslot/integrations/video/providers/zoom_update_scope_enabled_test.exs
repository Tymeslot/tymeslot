defmodule Tymeslot.Integrations.Video.Providers.ZoomUpdateScopeEnabledTest do
  @moduledoc """
  Covers the deployment where the Zoom app *is* configured for
  `meeting:update:meeting`.

  Every other Zoom test runs with the scope disabled, which is the default and
  the safe state. This module drives the other side of that switch: once the
  scope is obtainable, a grant that lacks it is a stale grant the account owner
  can fix, so it must be flagged and they must be told — the exact behaviour
  that would be a lie while the scope is unobtainable.
  """

  # Not async: `:zoom_update_scope_enabled` is application-wide.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

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

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:tymeslot, :zoom_update_scope_enabled, false)
    original_oauth = Application.get_env(:tymeslot, :zoom_oauth)

    Application.put_env(:tymeslot, :zoom_update_scope_enabled, true)

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

  describe "with the update scope enabled" do
    test "asks Zoom for meeting:update:meeting" do
      assert Scopes.requestable?(:update)
      assert Scopes.requested_scope() =~ "meeting:update:meeting"
      assert :update in Scopes.requested_operations()
    end

    test "includes the scope in the authorization URL" do
      url = ZoomOAuthHelper.authorization_url(123, "https://example.com/cb")
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["scope"] =~ "meeting:update:meeting"
    end

    test "asks the owner to reconnect when their grant predates the scope" do
      # The mirror of the disabled case: here reconnecting genuinely produces
      # the scope, so the badge is honest rather than an errand with no end.
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "valid_token",
          refresh_token: "valid_refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting meeting:read:meeting meeting:delete:meeting"
        })

      config = %{
        access_token: "valid_token",
        refresh_token: "valid_refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "meeting:write:meeting meeting:read:meeting meeting:delete:meeting",
        integration_id: integration.id,
        user_id: user.id,
        meeting_topic: "Test Meeting",
        meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      # No HTTP expectation: the pre-flight must short-circuit before any call.
      assert {:error, :insufficient_scope} =
               ZoomProvider.update_meeting_room("123456789", config)

      {:ok, reloaded} = VideoIntegrationQueries.get(integration.id)
      assert reloaded.needs_reauth
      assert reloaded.sync_error =~ "reschedule meetings"
    end

    test "the audit flags and emails a grant that predates the scope" do
      integration =
        insert(:video_integration,
          provider: "zoom",
          name: "Zoom",
          oauth_scope: "meeting:write:meeting meeting:read:meeting meeting:delete:meeting"
        )

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth
      assert reloaded.sync_error =~ "reschedule meetings"

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_reauth_notification",
          "user_id" => integration.user_id,
          "integration_id" => integration.id,
          "integration_type" => "video"
        }
      )
    end

    test "leaves a grant that already holds every requested scope alone" do
      integration =
        insert(:video_integration,
          provider: "zoom",
          name: "Zoom",
          oauth_scope:
            "meeting:write:meeting meeting:update:meeting meeting:read:meeting " <>
              "meeting:delete:meeting user:read:user"
        )

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute Repo.reload!(integration).needs_reauth
      refute_enqueued(worker: EmailWorker)
    end

    test "a reschedule succeeds once the grant carries the scope" do
      config = %{
        access_token: "valid_token",
        refresh_token: "valid_refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "meeting:write:meeting meeting:update:meeting meeting:read:meeting",
        meeting_topic: "Test Meeting",
        meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.update_meeting_room("123456789", config)
    end
  end
end
