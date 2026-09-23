defmodule TymeslotWeb.OAuthCallbackHandlerTest do
  @moduledoc """
  The error path every calendar and video OAuth callback shares. Each case runs
  against all five callback routes, so a provider cannot drift from the others
  unnoticed; the per-provider success paths live in the controller tests.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :controllers
  @moduletag :integrations

  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]

  alias Phoenix.Flash
  alias Tymeslot.Factory
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Security.RateLimiter

  @calendars "/dashboard/integrations?tab=calendars"
  @video "/dashboard/integrations?tab=video"

  # {callback path, where failures land, whether it is a Microsoft provider}
  @callbacks [
    {"/auth/google/calendar/callback", @calendars, false},
    {"/auth/outlook/calendar/callback", @calendars, true},
    {"/auth/google/video/callback", @video, false},
    {"/auth/teams/video/callback", @video, true},
    {"/auth/zoom/video/callback", @video, false}
  ]

  setup do
    RateLimiter.clear_all()

    for mod <- [State, RateLimiter] do
      try do
        :meck.unload(mod)
      rescue
        _error -> :ok
      end

      :meck.new(mod, [:passthrough])
    end

    originals =
      for key <- [:google_oauth, :outlook_oauth, :zoom_oauth] do
        original = Application.get_env(:tymeslot, key)
        Application.put_env(:tymeslot, key, Keyword.merge(original || [], state_secret: "secret"))
        {key, original}
      end

    on_exit(fn ->
      for mod <- [State, RateLimiter] do
        try do
          :meck.unload(mod)
        rescue
          _error -> :ok
        end
      end

      for {key, original} <- originals do
        if is_nil(original),
          do: Application.delete_env(:tymeslot, key),
          else: Application.put_env(:tymeslot, key, original)
      end
    end)

    :ok
  end

  for {path, failure_path, microsoft?} <- @callbacks do
    consent_message =
      if microsoft?, do: "requires admin approval", else: "Authorization was denied"

    describe path do
      test "access_denied says authorisation was denied", %{conn: conn} do
        conn = get(conn, unquote(path), %{"error" => "access_denied"})

        assert redirected_to(conn) == unquote(failure_path)
        assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
      end

      test "any other provider error says authentication failed", %{conn: conn} do
        conn = get(conn, unquote(path), %{"error" => "server_error"})

        assert redirected_to(conn) == unquote(failure_path)
        assert Flash.get(conn.assigns.flash, :error) =~ "Authentication failed"
      end

      test "an admin-consent code is explained only for Microsoft", %{conn: conn} do
        conn =
          get(conn, unquote(path), %{
            "error" => "access_denied",
            "error_description" => "AADSTS65001: The user or administrator has not consented."
          })

        assert redirected_to(conn) == unquote(failure_path)
        assert Flash.get(conn.assigns.flash, :error) =~ unquote(consent_message)
      end

      test "a response with neither code nor error is rejected", %{conn: conn} do
        conn = get(conn, unquote(path), %{"unrelated" => "junk"})

        assert redirected_to(conn) == unquote(failure_path)
        assert Flash.get(conn.assigns.flash, :error) =~ "Invalid authentication response"
      end

      test "a rate-limited callback is turned away", %{conn: conn} do
        user = Factory.insert(:user)
        conn = log_in_user(conn, user)
        :meck.expect(State, :validate, fn _state, _secret -> {:ok, %{user_id: user.id}} end)

        :meck.expect(RateLimiter, :check_oauth_callback_rate_limit, fn _ip ->
          {:error, :rate_limited, "limited"}
        end)

        conn = get(conn, unquote(path), %{"code" => "code", "state" => "state"})

        assert redirected_to(conn) == unquote(failure_path)
        assert Flash.get(conn.assigns.flash, :error) =~ "Too many authentication attempts"
      end
    end
  end
end
