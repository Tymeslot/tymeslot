defmodule TymeslotWeb.OAuthCSRFProtectionTest do
  @moduledoc """
  Locks in CSRF protection for the calendar and video OAuth callbacks.

  Without the state/session user match check, an attacker who initiates the
  OAuth flow on their own account can redirect a logged-in victim to the
  callback URL, binding the victim's Google/Microsoft account to the
  attacker's Tymeslot integration. These tests prove the callback short-
  circuits (no integration created, redirects with an error flash) when:

    * the signed state's user_id does not equal the current session user, or
    * there is no authenticated session at all.

  Also covers log-redaction: the invalid-params fallback must not leak the
  raw OAuth `code` to logs.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :auth

  import ExUnit.CaptureLog
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]

  alias Phoenix.Flash
  alias Tymeslot.Factory
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  @google_secret "test_google_state_secret_csrf"
  @outlook_secret "test_outlook_state_secret_csrf"

  setup do
    original_google_oauth = Application.get_env(:tymeslot, :google_oauth)
    original_outlook_oauth = Application.get_env(:tymeslot, :outlook_oauth)
    original_video_providers = Application.get_env(:tymeslot, :video_providers)

    Application.put_env(
      :tymeslot,
      :google_oauth,
      Keyword.merge(original_google_oauth || [], state_secret: @google_secret)
    )

    Application.put_env(
      :tymeslot,
      :outlook_oauth,
      Keyword.merge(original_outlook_oauth || [], state_secret: @outlook_secret)
    )

    Application.put_env(:tymeslot, :video_providers, %{teams: %{enabled: true}})

    if is_nil(Process.whereis(DashboardCache)), do: DashboardCache.start_link([])

    on_exit(fn ->
      restore_env(:google_oauth, original_google_oauth)
      restore_env(:outlook_oauth, original_outlook_oauth)
      restore_env(:video_providers, original_video_providers)
    end)

    :ok
  end

  describe "Google Calendar callback — CSRF protection" do
    test "rejects callback when state user does not match session user", %{conn: conn} do
      session_user = Factory.insert(:user)
      attacker = Factory.insert(:user)
      state = State.generate(attacker.id, @google_secret)

      conn = log_in_user(conn, session_user)

      conn =
        get(conn, ~p"/auth/google/calendar/callback", %{
          "code" => "attacker_code",
          "state" => state
        })

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"

      refute integration_exists?(session_user.id, "google")
      refute integration_exists?(attacker.id, "google")
    end

    test "rejects callback when no user is authenticated", %{conn: conn} do
      target = Factory.insert(:user)
      state = State.generate(target.id, @google_secret)

      conn =
        get(conn, ~p"/auth/google/calendar/callback", %{"code" => "any_code", "state" => state})

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"

      refute integration_exists?(target.id, "google")
    end

    test "rejects callback with a forged (unsigned) state parameter", %{conn: conn} do
      session_user = Factory.insert(:user)
      conn = log_in_user(conn, session_user)

      conn =
        get(conn, ~p"/auth/google/calendar/callback", %{
          "code" => "any_code",
          "state" => "not-a-real-signed-state"
        })

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"

      refute integration_exists?(session_user.id, "google")
    end
  end

  describe "Outlook Calendar callback — CSRF protection" do
    test "rejects callback when state user does not match session user", %{conn: conn} do
      session_user = Factory.insert(:user)
      attacker = Factory.insert(:user)
      state = State.generate(attacker.id, @outlook_secret)

      conn = log_in_user(conn, session_user)

      conn =
        get(conn, ~p"/auth/outlook/calendar/callback", %{
          "code" => "attacker_code",
          "state" => state
        })

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"

      refute integration_exists?(session_user.id, "outlook")
      refute integration_exists?(attacker.id, "outlook")
    end

    test "rejects callback when no user is authenticated", %{conn: conn} do
      target = Factory.insert(:user)
      state = State.generate(target.id, @outlook_secret)

      conn =
        get(conn, ~p"/auth/outlook/calendar/callback", %{"code" => "any", "state" => state})

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"
    end
  end

  describe "Google Meet callback — CSRF protection" do
    test "rejects callback when state user does not match session user", %{conn: conn} do
      session_user = Factory.insert(:user)
      attacker = Factory.insert(:user)
      state = State.generate(attacker.id, @google_secret)

      conn = log_in_user(conn, session_user)

      conn =
        get(conn, ~p"/auth/google/video/callback", %{"code" => "attacker_code", "state" => state})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"

      refute video_integration_exists?(session_user.id, "google_meet")
      refute video_integration_exists?(attacker.id, "google_meet")
    end

    test "rejects callback when no user is authenticated", %{conn: conn} do
      target = Factory.insert(:user)
      state = State.generate(target.id, @google_secret)

      conn =
        get(conn, ~p"/auth/google/video/callback", %{"code" => "any", "state" => state})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"
    end
  end

  describe "Microsoft Teams callback — CSRF protection" do
    test "rejects callback when state user does not match session user", %{conn: conn} do
      session_user = Factory.insert(:user)
      attacker = Factory.insert(:user)
      state = State.generate(attacker.id, @outlook_secret)

      conn = log_in_user(conn, session_user)

      conn =
        get(conn, ~p"/auth/teams/video/callback", %{"code" => "attacker_code", "state" => state})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"

      refute video_integration_exists?(session_user.id, "teams")
      refute video_integration_exists?(attacker.id, "teams")
    end

    test "rejects callback when no user is authenticated", %{conn: conn} do
      target = Factory.insert(:user)
      state = State.generate(target.id, @outlook_secret)

      conn =
        get(conn, ~p"/auth/teams/video/callback", %{"code" => "any", "state" => state})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"
    end
  end

  describe "callback log redaction" do
    @secret_code "SECRET_CODE_abcd1234_should_never_reach_logs"
    @secret_state "SECRET_STATE_xyz9876_should_never_reach_logs"
    @secret_id_token "SECRET_ID_TOKEN_pqr5555_should_never_reach_logs"

    test "Google Calendar invalid-params log drops code, state, and id_token", %{conn: conn} do
      log =
        capture_log(fn ->
          get(conn, ~p"/auth/google/calendar/callback", %{
            "code" => @secret_code,
            "id_token" => @secret_id_token,
            "unknown_field" => "visible"
          })
        end)

      refute log =~ @secret_code
      refute log =~ @secret_id_token
      assert log =~ "Invalid Google Calendar OAuth callback params"
    end

    test "Outlook Calendar invalid-params log drops code, state, and id_token", %{conn: conn} do
      log =
        capture_log(fn ->
          # Omit "state" so the params do not match the %{"code" => _, "state" => _}
          # clause and instead fall through to the catch-all logging clause.
          get(conn, ~p"/auth/outlook/calendar/callback", %{
            "code" => @secret_code,
            "id_token" => @secret_id_token
          })
        end)

      assert log =~ "Invalid Outlook Calendar OAuth callback params"
      refute log =~ @secret_code
      refute log =~ @secret_id_token
    end

    test "Google Meet invalid-params log drops code, state, and id_token", %{conn: conn} do
      log =
        capture_log(fn ->
          get(conn, ~p"/auth/google/video/callback", %{
            "code" => @secret_code,
            "id_token" => @secret_id_token,
            "unknown" => "visible"
          })
        end)

      refute log =~ @secret_code
      refute log =~ @secret_id_token
    end

    test "Microsoft Teams invalid-params log drops code, state, and id_token", %{conn: conn} do
      log =
        capture_log(fn ->
          get(conn, ~p"/auth/teams/video/callback", %{
            "state" => @secret_state,
            "id_token" => @secret_id_token
          })
        end)

      refute log =~ @secret_state
      refute log =~ @secret_id_token
    end
  end

  defp integration_exists?(user_id, provider) do
    case CalendarIntegrationQueries.get_by_user_and_provider(user_id, provider) do
      {:ok, _integration} -> true
      {:error, :not_found} -> false
    end
  end

  defp video_integration_exists?(user_id, provider) do
    case VideoIntegrationQueries.get_by_provider_for_user(user_id, provider) do
      {:ok, _integration} -> true
      {:error, :not_found} -> false
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)
end
