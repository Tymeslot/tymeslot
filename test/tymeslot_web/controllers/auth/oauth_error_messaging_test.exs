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
    test "access_denied maps to 'Authorization was denied'", %{conn: conn} do
      conn = get(conn, "/auth/google/calendar/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/calendar-integration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "other error codes fall through to generic 'Authentication failed'",
         %{conn: conn} do
      conn =
        get(conn, "/auth/google/calendar/callback", %{
          "error" => "server_error",
          "state" => "anything"
        })

      assert redirected_to(conn) == "/dashboard/calendar-integration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authentication failed"
    end
  end

  describe "CalendarOAuthController.outlook_callback/2 — provider error params" do
    test "Microsoft admin-consent AADSTS65001 maps to the admin-approval message",
         %{conn: conn} do
      # AADSTS65001 is the canonical "user or administrator has not
      # consented" code. The message must route the user to IT, not
      # leave them retrying the same flow.
      conn =
        get(conn, "/auth/outlook/calendar/callback", %{
          "error" => "consent_required",
          "error_description" => "AADSTS65001: The user or administrator has not consented"
        })

      assert redirected_to(conn) == "/dashboard/calendar-integration"
      assert Flash.get(conn.assigns.flash, :error) =~ "admin approval"
    end

    test "access_denied without an AADSTS code uses the standard denial message",
         %{conn: conn} do
      conn =
        get(conn, "/auth/outlook/calendar/callback", %{
          "error" => "access_denied",
          "error_description" => "user cancelled"
        })

      assert redirected_to(conn) == "/dashboard/calendar-integration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end
  end

  describe "VideoOAuthController.google_callback/2 — provider error params" do
    test "access_denied maps to 'Authorization was denied'", %{conn: conn} do
      conn = get(conn, "/auth/google/video/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == "/dashboard/video-integration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end

    test "invalid params (no code, no error) redirect with 'Invalid authentication response'",
         %{conn: conn} do
      conn = get(conn, "/auth/google/video/callback", %{})

      assert redirected_to(conn) == "/dashboard/video-integration"
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

      assert redirected_to(conn) == "/dashboard/video-integration"
      assert Flash.get(conn.assigns.flash, :error) =~ "admin approval"
    end

    test "server_error with no AADSTS code falls through to 'Authentication failed'",
         %{conn: conn} do
      conn =
        get(conn, "/auth/teams/video/callback", %{
          "error" => "server_error",
          "error_description" => "transient upstream failure"
        })

      assert redirected_to(conn) == "/dashboard/video-integration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Authentication failed"
    end
  end
end
