defmodule TymeslotWeb.CalendarOAuthControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  alias Phoenix.Flash
  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Factory
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Integrations.Calendar.Google.OAuthHelper, as: GoogleCalendarOAuthHelper
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper, as: OutlookCalendarOAuthHelper
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Security.RateLimiter

  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]

  setup do
    RateLimiter.clear_all()

    modules = [GoogleCalendarOAuthHelper, OutlookCalendarOAuthHelper, State]

    for mod <- modules do
      try do
        :meck.unload(mod)
      rescue
        _error -> :ok
      end

      :meck.new(mod, [:passthrough])
    end

    # OAuthStateGuard.provider_secret/1 raises if these aren't set, even when
    # State.validate/2 is mecked — provider_secret/1 is evaluated as an
    # argument before the mecked call is invoked.
    original_google_oauth = Application.get_env(:tymeslot, :google_oauth)
    original_outlook_oauth = Application.get_env(:tymeslot, :outlook_oauth)

    Application.put_env(
      :tymeslot,
      :google_oauth,
      Keyword.merge(original_google_oauth || [], state_secret: "test_google_state_secret")
    )

    Application.put_env(
      :tymeslot,
      :outlook_oauth,
      Keyword.merge(original_outlook_oauth || [], state_secret: "test_outlook_state_secret")
    )

    case Process.whereis(DashboardCache) do
      nil -> DashboardCache.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      for mod <- modules do
        try do
          :meck.unload(mod)
        rescue
          _error -> :ok
        end
      end

      if is_nil(original_google_oauth) do
        Application.delete_env(:tymeslot, :google_oauth)
      else
        Application.put_env(:tymeslot, :google_oauth, original_google_oauth)
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
      conn = authenticate_state_user(conn, 123)

      :meck.expect(GoogleCalendarOAuthHelper, :handle_callback, fn "code", _state, _uri ->
        {:ok, %{user_id: 123}}
      end)

      conn =
        get(conn, ~p"/auth/google/calendar/callback", %{"code" => "code", "state" => "state"})

      # A successful connect lands on the calendar, not the integrations tab.
      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Google Calendar connected successfully"
    end

    test "outlook_callback handles success", %{conn: conn} do
      conn = authenticate_state_user(conn, 123)

      :meck.expect(OutlookCalendarOAuthHelper, :handle_callback, fn "code", _state, _uri ->
        {:ok, %{user_id: 123}}
      end)

      conn =
        get(conn, ~p"/auth/outlook/calendar/callback", %{"code" => "code", "state" => "state"})

      # A successful connect lands on the calendar, not the integrations tab.
      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Outlook Calendar connected successfully"
    end

    test "google_callback handles error from provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/calendar/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "google_callback handles invalid params", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/calendar/callback", %{"invalid" => "params"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid authentication response"
    end

    test "outlook_callback handles error from provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/outlook/calendar/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "outlook_callback surfaces admin consent message when AADSTS code is present", %{
      conn: conn
    } do
      for code <- ~w[AADSTS65001 AADSTS90094 AADSTS90093 AADSTS90095] do
        conn =
          get(conn, ~p"/auth/outlook/calendar/callback", %{
            "error" => "access_denied",
            "error_description" =>
              "#{code}: The user or administrator has not consented to use the application."
          })

        assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"

        assert Flash.get(conn.assigns.flash, :error) =~
                 "requires admin approval"
      end
    end

    test "outlook_callback handles exchange failure", %{conn: conn} do
      conn = authenticate_state_user(conn, 123)

      :meck.expect(OutlookCalendarOAuthHelper, :handle_callback, fn _code, _state, _uri ->
        {:error, :invalid_code}
      end)

      conn =
        get(conn, ~p"/auth/outlook/calendar/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "Failed to connect Outlook Calendar"
    end

    test "google_callback handles :calendar_scope_missing — redirects with instructional flash",
         %{conn: conn} do
      conn = authenticate_state_user(conn, 123)

      :meck.expect(GoogleCalendarOAuthHelper, :handle_callback, fn _code, _state, _uri ->
        {:error, :calendar_scope_missing}
      end)

      conn =
        get(conn, ~p"/auth/google/calendar/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"

      assert Flash.get(conn.assigns.flash, :error) =~
               "Calendar permission was not granted"
    end
  end

  describe "dashboard integration status after connecting" do
    # The dashboard caches whether the user has a calendar for five minutes. A
    # connect that leaves the cached "no calendar" in place keeps nagging the
    # user to connect the calendar they just connected.
    for {path, helper, provider} <- [
          {"/auth/google/calendar/callback", GoogleCalendarOAuthHelper, "google"},
          {"/auth/outlook/calendar/callback", OutlookCalendarOAuthHelper, "outlook"}
        ] do
      test "#{provider} connect refreshes the cached status", %{conn: conn} do
        user = Factory.insert(:user)
        conn = log_in_user(conn, user)
        :meck.expect(State, :validate, fn _state, _secret -> {:ok, %{user_id: user.id}} end)
        assert %{has_calendar: false} = DashboardContext.get_integration_status(user.id)

        :meck.expect(unquote(helper), :handle_callback, fn _code, _state, _uri ->
          {:ok, Factory.insert(:calendar_integration, user: user, provider: unquote(provider))}
        end)

        conn = get(conn, unquote(path), %{"code" => "code", "state" => "state"})

        assert redirected_to(conn) == "/dashboard"
        assert %{has_calendar: true} = DashboardContext.get_integration_status(user.id)
      end
    end
  end

  describe "return_to" do
    # The redirect target comes from the state only once the state has been
    # verified: the raw "state" parameter here embeds nothing, so a redirect to
    # the validated path proves where it was read from.
    test "a successful connect lands on the validated return_to", %{conn: conn} do
      user = Factory.insert(:user, id: 123)
      conn = log_in_user(conn, user)

      :meck.expect(State, :validate, fn _state, _secret ->
        {:ok, %{user_id: 123, integration_id: nil, return_to: "/dashboard/onboarding"}}
      end)

      :meck.expect(OutlookCalendarOAuthHelper, :handle_callback, fn _code, _state, _uri ->
        {:ok, %{user_id: 123}}
      end)

      conn =
        get(conn, ~p"/auth/outlook/calendar/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/onboarding"
    end

    test "a failed connect also returns to the validated return_to", %{conn: conn} do
      user = Factory.insert(:user, id: 123)
      conn = log_in_user(conn, user)

      :meck.expect(State, :validate, fn _state, _secret ->
        {:ok, %{user_id: 123, integration_id: nil, return_to: "/dashboard/onboarding"}}
      end)

      :meck.expect(GoogleCalendarOAuthHelper, :handle_callback, fn _code, _state, _uri ->
        {:error, :invalid_code}
      end)

      conn =
        get(conn, ~p"/auth/google/calendar/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/dashboard/onboarding"
      assert Flash.get(conn.assigns.flash, :error) =~ "Failed to connect Google Calendar"
    end

    test "a rejected state ignores the return_to it carries", %{conn: conn} do
      user = Factory.insert(:user, id: 123)
      conn = log_in_user(conn, user)
      state = State.generate(123, "wrong_secret", nil, return_to: "/dashboard/onboarding")

      conn = get(conn, ~p"/auth/outlook/calendar/callback", %{"code" => "code", "state" => state})

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "session mismatch"
    end
  end

  # Logs a user in and redirects the mecked `State.validate/2` to return the
  # same id so the new `OAuthStateGuard.enforce_user_match/3` passes.
  defp authenticate_state_user(conn, user_id) do
    user = Factory.insert(:user, id: user_id)
    conn = log_in_user(conn, user)
    :meck.expect(State, :validate, fn _state, _secret -> {:ok, %{user_id: user_id}} end)
    conn
  end
end
