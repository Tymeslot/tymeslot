defmodule TymeslotWeb.OAuthErrorMessagingTest do
  @moduledoc """
  Locks in the user-facing error messages produced by the calendar and
  video OAuth callbacks when the provider returns an `error=` parameter.

  The CSRF / state-mismatch branches are already pinned by
  `oauth_csrf_protection_test.exs`. This file fills the other gap
  identified in the controller audit — the provider-error branches
  (`access_denied`, Microsoft admin-consent AADSTS codes, and
  everything else) — so a refactor can't accidentally replace a
  specific, actionable flash ("Your Microsoft organisation requires
  admin approval…") with a generic "Authentication failed" that
  sends the user running to support.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :controllers

  alias Phoenix.Flash

  describe "CalendarOAuthController.google_callback/2 — provider error params" do
    test "other error codes fall through to generic 'Authentication failed'",
         %{conn: conn} do
      conn =
        get(conn, "/auth/google/calendar/callback", %{
          "error" => "server_error",
          "state" => "anything"
        })

      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authentication failed"
    end
  end

  describe "VideoOAuthController.google_callback/2 — provider error params" do
    test "access_denied maps to 'Authorization was denied'", %{conn: conn} do
      conn = get(conn, "/auth/google/video/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "invalid params (no code, no error) redirect with 'Invalid authentication response'",
         %{conn: conn} do
      conn = get(conn, "/auth/google/video/callback", %{})

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid authentication response"
    end
  end

  describe "VideoOAuthController.teams_callback/2 — provider error params" do
    test "Microsoft admin-consent AADSTS90094 maps to the admin-approval message",
         %{conn: conn} do
      conn =
        get(conn, "/auth/teams/video/callback", %{
          "error" => "consent_required",
          "error_description" => "AADSTS90094: Admin consent required"
        })

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "admin approval"
    end

    test "server_error with no AADSTS code falls through to 'Authentication failed'",
         %{conn: conn} do
      conn =
        get(conn, "/auth/teams/video/callback", %{
          "error" => "server_error",
          "error_description" => "transient upstream failure"
        })

      assert redirected_to(conn) == "/dashboard/integrations?tab=video"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authentication failed"
    end
  end
end
