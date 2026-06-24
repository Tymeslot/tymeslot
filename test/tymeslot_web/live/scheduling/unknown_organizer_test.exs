defmodule TymeslotWeb.Scheduling.UnknownOrganizerTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :scheduling

  # An unknown organizer username resolves a route (`/:username` and its nested
  # scheduling paths) but no profile exists, so the dispatcher mount raises
  # `TymeslotWeb.NotFoundError`. The dead render must surface a real 404 via
  # `Plug.Exception` rather than the old soft-404 redirect to "/".

  describe "GET /:username for an unknown organizer" do
    test "returns a real 404 instead of redirecting home", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, "/nobody-here-xyz") end)
    end

    test "nested scheduling routes also return a real 404", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, "/nobody-here-xyz/quick-chat") end)
    end
  end
end
