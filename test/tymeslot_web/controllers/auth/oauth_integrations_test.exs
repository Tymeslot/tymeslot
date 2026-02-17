defmodule TymeslotWeb.OAuthIntegrationsControllerTest do
  use TymeslotWeb.ConnCase, async: false

  alias Phoenix.Flash
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.Factory
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Integrations.Calendar.Google.OAuthHelper, as: GoogleCalendarOAuthHelper
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper, as: OutlookCalendarOAuthHelper
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper

  setup do
    modules = [
      GoogleCalendarOAuthHelper,
      OutlookCalendarOAuthHelper,
      GoogleOAuthHelper,
      TeamsOAuthHelper,
      State,
      VideoIntegrationQueries
    ]

    for mod <- modules do
      try do
        :meck.unload(mod)
      rescue
        _error -> :ok
      end

      :meck.new(mod, [:passthrough])
    end

    # Ensure required OAuth state secret exists (VideoOAuthController.state_secret/0 can raise)
    original_outlook_oauth = Application.get_env(:tymeslot, :outlook_oauth)

    Application.put_env(
      :tymeslot,
      :outlook_oauth,
      Keyword.merge(original_outlook_oauth || [], state_secret: "test_state_secret")
    )

    case Process.whereis(DashboardCache) do
      nil -> DashboardCache.start_link([])
      _pid -> :ok
    end

    # Enable teams provider for tests
    original_video_providers = Application.get_env(:tymeslot, :video_providers)
    Application.put_env(:tymeslot, :video_providers, %{teams: %{enabled: true}})

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

      if is_nil(original_outlook_oauth) do
        Application.delete_env(:tymeslot, :outlook_oauth)
      else
        Application.put_env(:tymeslot, :outlook_oauth, original_outlook_oauth)
      end
    end)

    :ok
  end

  describe "CalendarOAuthController" do
    test "google_callback handles success", %{conn: conn} do
      :meck.expect(GoogleCalendarOAuthHelper, :handle_callback, fn "code", "state", _uri ->
        {:ok, %{user_id: 123}}
      end)

      conn =
        get(conn, ~p"/auth/google/calendar/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/calendar"
      assert Flash.get(conn.assigns.flash, :info) =~ "Google Calendar connected successfully"
    end

    test "outlook_callback handles success", %{conn: conn} do
      :meck.expect(OutlookCalendarOAuthHelper, :handle_callback, fn "code", "state", _uri ->
        {:ok, %{user_id: 123}}
      end)

      conn =
        get(conn, ~p"/auth/outlook/calendar/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/calendar"
      assert Flash.get(conn.assigns.flash, :info) =~ "Outlook Calendar connected successfully"
    end

    test "google_callback handles error from provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/calendar/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/calendar"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "google_callback handles invalid params", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/calendar/callback", %{"invalid" => "params"})

      assert redirected_to(conn) == "/dashboard/calendar"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid authentication response"
    end

    test "outlook_callback handles error from provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/outlook/calendar/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/calendar"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "outlook_callback handles exchange failure", %{conn: conn} do
      :meck.expect(OutlookCalendarOAuthHelper, :handle_callback, fn _code, _state, _uri ->
        {:error, :invalid_code}
      end)

      conn =
        get(conn, ~p"/auth/outlook/calendar/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/calendar"
      assert Flash.get(conn.assigns.flash, :error) =~ "Failed to connect Outlook Calendar"
    end
  end

  describe "VideoOAuthController" do
    setup do
      :meck.expect(State, :validate, fn _state, _secret -> {:ok, %{user_id: 123}} end)
      :ok
    end

    test "google_callback (Meet) handles success", %{conn: conn} do
      user_id = 123

      :meck.expect(GoogleOAuthHelper, :exchange_code_for_tokens, fn "code", _uri, "state" ->
        {:ok,
         %{
           user_id: user_id,
           access_token: "at",
           refresh_token: "rt",
           expires_at: DateTime.utc_now(),
           scope: "scope"
         }}
      end)

      # Mock VideoIntegrationQueries to succeed
      integration = %Tymeslot.DatabaseSchemas.VideoIntegrationSchema{
        id: 1,
        user_id: user_id,
        name: "Google Meet",
        provider: "google_meet"
      }

      :meck.expect(VideoIntegrationQueries, :create, fn _attrs ->
        {:ok, integration}
      end)

      Factory.insert(:user, id: user_id)

      conn = get(conn, ~p"/auth/google/video/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/video"
      assert Flash.get(conn.assigns.flash, :info) =~ "Google Meet connected successfully"
    end

    test "teams_callback handles success", %{conn: conn} do
      user_id = 456

      :meck.expect(TeamsOAuthHelper, :exchange_code_for_tokens, fn "code", _uri, "state" ->
        {:ok,
         %{
           user_id: user_id,
           access_token: "at",
           refresh_token: "rt",
           expires_at: DateTime.utc_now(),
           scope: "scope",
           tenant_id: "test-tenant-id",
           teams_user_id: "test-teams-user-id"
         }}
      end)

      # Mock VideoIntegrationQueries to succeed
      integration = %Tymeslot.DatabaseSchemas.VideoIntegrationSchema{
        id: 1,
        user_id: user_id,
        name: "Microsoft Teams",
        provider: "teams"
      }

      :meck.expect(VideoIntegrationQueries, :create, fn _attrs ->
        {:ok, integration}
      end)

      Factory.insert(:user, id: user_id)

      conn = get(conn, ~p"/auth/teams/video/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/video"
      assert Flash.get(conn.assigns.flash, :info) =~ "Microsoft Teams connected successfully"
    end

    test "google_callback handles invalid state", %{conn: conn} do
      :meck.expect(State, :validate, fn _state, _secret -> {:error, :expired} end)

      conn = get(conn, ~p"/auth/google/video/callback", %{"code" => "code", "state" => "invalid"})

      assert redirected_to(conn) == "/dashboard/video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid authentication state"
    end

    test "google_callback handles provider error", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/video/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "teams_callback handles creation failure", %{conn: conn} do
      user_id = 789

      :meck.expect(TeamsOAuthHelper, :exchange_code_for_tokens, fn _code, _uri, _state ->
        {:ok,
         %{
           user_id: user_id,
           access_token: "at",
           refresh_token: "rt",
           expires_at: DateTime.utc_now(),
           scope: "scope",
           tenant_id: "test-tenant-id",
           teams_user_id: "test-teams-user-id"
         }}
      end)

      :meck.expect(VideoIntegrationQueries, :create, fn _client -> {:error, :db_error} end)

      Factory.insert(:user, id: user_id)

      conn = get(conn, ~p"/auth/teams/video/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Failed to connect Microsoft Teams"
    end

    test "teams_callback handles missing tenant_id or teams_user_id", %{conn: conn} do
      user_id = 999

      :meck.expect(TeamsOAuthHelper, :exchange_code_for_tokens, fn _code, _uri, _state ->
        {:ok,
         %{
           user_id: user_id,
           access_token: "at",
           refresh_token: "rt",
           expires_at: DateTime.utc_now(),
           scope: "scope"
           # tenant_id and teams_user_id are missing
         }}
      end)

      Factory.insert(:user, id: user_id)

      conn = get(conn, ~p"/auth/teams/video/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/video"

      assert Flash.get(conn.assigns.flash, :error) =~
               "Missing required Microsoft Teams information"
    end
  end
end
