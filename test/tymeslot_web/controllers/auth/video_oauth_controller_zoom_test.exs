defmodule TymeslotWeb.VideoOAuthControllerZoomTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :integrations

  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]

  alias Phoenix.Flash
  alias Tymeslot.Factory
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper
  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()

    modules = [ZoomOAuthHelper, State, VideoIntegrationQueries]

    for mod <- modules do
      try do
        :meck.unload(mod)
      rescue
        _error -> :ok
      end

      :meck.new(mod, [:passthrough])
    end

    original_zoom_oauth = Application.get_env(:tymeslot, :zoom_oauth)

    Application.put_env(
      :tymeslot,
      :zoom_oauth,
      Keyword.merge(original_zoom_oauth || [], state_secret: "test_zoom_state_secret")
    )

    case Process.whereis(DashboardCache) do
      nil -> DashboardCache.start_link([])
      _pid -> :ok
    end

    original_video_providers = Application.get_env(:tymeslot, :video_providers)
    Application.put_env(:tymeslot, :video_providers, %{zoom: %{enabled: true}})

    on_exit(fn ->
      for mod <- modules do
        try do
          :meck.unload(mod)
        rescue
          _error -> :ok
        end
      end

      if is_nil(original_video_providers) do
        Application.delete_env(:tymeslot, :video_providers)
      else
        Application.put_env(:tymeslot, :video_providers, original_video_providers)
      end

      if is_nil(original_zoom_oauth) do
        Application.delete_env(:tymeslot, :zoom_oauth)
      else
        Application.put_env(:tymeslot, :zoom_oauth, original_zoom_oauth)
      end
    end)

    :ok
  end

  describe "zoom_callback/2" do
    test "creates a new Zoom integration on success", %{conn: conn} do
      user_id = 5001
      conn = authenticate_state_user(conn, user_id)

      :meck.expect(ZoomOAuthHelper, :exchange_code_for_tokens, fn "code", _uri, "state" ->
        {:ok,
         %{
           user_id: user_id,
           access_token: "at",
           refresh_token: "rt",
           expires_at: DateTime.utc_now(),
           scope: "meeting:write:meeting",
           provider_account_id: "zoom-user-1",
           provider_account_email: "alice@example.com"
         }}
      end)

      integration = %VideoIntegrationSchema{
        id: 1,
        user_id: user_id,
        name: "Zoom",
        provider: "zoom"
      }

      :meck.expect(VideoIntegrationQueries, :get_any_by_account_for_user, fn ^user_id,
                                                                             "zoom",
                                                                             "zoom-user-1" ->
        {:error, :not_found}
      end)

      :meck.expect(VideoIntegrationQueries, :get_by_account_for_user, fn ^user_id,
                                                                         "zoom",
                                                                         "zoom-user-1" ->
        {:error, :not_found}
      end)

      :meck.expect(VideoIntegrationQueries, :create, fn attrs ->
        assert attrs.user_id == user_id
        assert attrs.provider == "zoom"
        assert attrs.name == "Zoom"
        assert attrs.provider_account_id == "zoom-user-1"
        assert attrs.provider_account_email == "alice@example.com"
        {:ok, integration}
      end)

      conn = get(conn, ~p"/auth/zoom/video/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :info) =~ "Zoom connected successfully"
    end

    test "shows access_denied message when user declines authorisation", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/zoom/video/callback", %{
          "error" => "access_denied",
          "error_description" => "User cancelled"
        })

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "rejects state signed with a different provider's secret", %{conn: conn} do
      user_id = 5002
      user = Factory.insert(:user, id: user_id)
      conn = log_in_user(conn, user)
      :meck.expect(State, :validate, fn _state, _secret -> {:error, :tampered} end)

      conn = get(conn, ~p"/auth/zoom/video/callback", %{"code" => "code", "state" => "bad"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"
    end

    test "rejects callback when provider_account_id is missing", %{conn: conn} do
      user_id = 5003
      conn = authenticate_state_user(conn, user_id)

      :meck.expect(ZoomOAuthHelper, :exchange_code_for_tokens, fn _code, _uri, _state ->
        {:ok,
         %{
           user_id: user_id,
           access_token: "at",
           refresh_token: "rt",
           expires_at: DateTime.utc_now(),
           scope: "meeting:write:meeting"
           # provider_account_id intentionally missing
         }}
      end)

      conn = get(conn, ~p"/auth/zoom/video/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Could not identify your Zoom account"
    end

    test "handles invalid callback params (no code, no error)", %{conn: conn} do
      conn = get(conn, ~p"/auth/zoom/video/callback", %{"unrelated" => "junk"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid authentication response"
    end
  end

  defp authenticate_state_user(conn, user_id) do
    user = Factory.insert(:user, id: user_id)
    conn = log_in_user(conn, user)
    :meck.expect(State, :validate, fn _state, _secret -> {:ok, %{user_id: user_id}} end)
    conn
  end
end
