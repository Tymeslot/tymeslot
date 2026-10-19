defmodule TymeslotWeb.Integrations.OAuthCallbackHandlerTest do
  @moduledoc """
  The error path every calendar and video OAuth callback shares. Each case runs
  against all five callback routes, so a provider cannot drift from the others
  unnoticed; the per-provider success paths live in the controller tests.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :controllers
  @moduletag :integrations

  import Ecto.Query, only: [from: 2]
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.RateLimiterTestHelpers, only: [exhaust_limit!: 2]

  alias Phoenix.Flash
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Factory
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias TymeslotWeb.Helpers.ClientIP

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

  @state_secret "secret"

  setup do
    originals =
      for key <- [:google_oauth, :outlook_oauth, :zoom_oauth] do
        original = Application.get_env(:tymeslot, key)

        Application.put_env(
          :tymeslot,
          key,
          Keyword.merge(original || [], state_secret: @state_secret)
        )

        {key, original}
      end

    on_exit(fn ->
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
      if microsoft?, do: "requires admin approval", else: "Authorisation was denied"

    describe path do
      test "access_denied says authorisation was denied", %{conn: conn} do
        conn = get(conn, unquote(path), %{"error" => "access_denied"})

        assert redirected_to(conn) == unquote(failure_path)
        assert Flash.get(conn.assigns.flash, :error) =~ "Authorisation was denied"
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

      test "an account pending deletion is sent to the restore page and connects nothing",
           %{conn: conn} do
        user = Factory.insert(:user)
        now = DateTime.utc_now(:second)

        {:ok, pending} =
          UserQueries.mark_deletion_scheduled(user, now, DateTime.add(now, 14, :day))

        conn = log_in_user(conn, pending)

        # A state that would pass, so the callback could only be stopped by
        # the pending deletion, before any of it is checked or used.
        state = State.generate(user.id, @state_secret)
        conn = get(conn, unquote(path), %{"code" => "code", "state" => state})

        assert redirected_to(conn) == "/auth/restore"
        assert Flash.get(conn.assigns.flash, :error) == nil
        assert Flash.get(conn.assigns.flash, :info) == nil

        for schema <- [CalendarIntegrationSchema, VideoIntegrationSchema] do
          assert Repo.all(from(i in schema, where: i.user_id == ^user.id)) == []
        end
      end

      test "a rate-limited callback is turned away", %{conn: conn} do
        user = Factory.insert(:user)
        conn = conn |> with_own_address() |> log_in_user(user)
        exhaust_limit!(:oauth_callback, ClientIP.get(conn))

        state = State.generate(user.id, @state_secret)
        conn = get(conn, unquote(path), %{"code" => "code", "state" => state})

        assert redirected_to(conn) == unquote(failure_path)
        assert Flash.get(conn.assigns.flash, :error) =~ "Too many authentication attempts"
      end
    end
  end

  # An address of the test's own, so the bucket it exhausts is charged by no
  # other test.
  defp with_own_address(conn) do
    n = System.unique_integer([:positive])
    %{conn | remote_ip: {10, 79, div(rem(n, 62_500), 250), rem(n, 250) + 1}}
  end
end
