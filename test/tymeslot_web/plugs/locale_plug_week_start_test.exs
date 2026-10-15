defmodule TymeslotWeb.Plugs.LocalePlugWeekStartTest do
  @moduledoc """
  `LocalePlug` reads the visitor's first day of the week from the
  `Accept-Language` header alone, and carries it to the LiveView session.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :i18n
  @moduletag :plugs

  alias TymeslotWeb.Plugs.LocalePlug

  test "comes from the header's region even when another locale is chosen", %{conn: conn} do
    conn =
      conn
      |> Map.put(:params, %{"locale" => "de"})
      |> fetch_session()
      |> put_req_header("accept-language", "en-US,en;q=0.8")
      |> LocalePlug.call([])

    assert conn.assigns.locale == "de"
    assert conn.assigns.visitor_week_start == :sunday
    assert LocalePlug.live_session_data(conn)["visitor_week_start"] == "sunday"
  end

  test "is left open without a header", %{conn: conn} do
    conn = conn |> Map.put(:params, %{}) |> fetch_session() |> LocalePlug.call([])

    assert conn.assigns.visitor_week_start == nil
    refute Map.has_key?(LocalePlug.live_session_data(conn), "visitor_week_start")
  end
end
