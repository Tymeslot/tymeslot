defmodule TymeslotWeb.Plugs.LocalePlugCandidatesTest do
  @moduledoc """
  `LocalePlug` carries the visitor's own pick and the browser's acceptable
  locales apart to the LiveView session, so a booking page offering only
  some languages can rank the pick above the browser
  (`Tymeslot.ContentTranslations.Languages.visitor_locale/2`).
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :i18n
  @moduletag :plugs

  alias TymeslotWeb.Plugs.LocalePlug

  test "the ?locale= pick, and the header's tags normalised, acceptable and without duplicates",
       %{conn: conn} do
    conn =
      conn
      |> Map.put(:params, %{"locale" => "fr"})
      |> fetch_session()
      |> put_req_header("accept-language", "xx, de-AT, fr;q=0.5, de;q=0.4, it;q=0")
      |> LocalePlug.call([])

    assert conn.assigns.locale_choice == "fr"
    assert conn.assigns.browser_locales == ["de", "fr"]

    assert %{"locale_choice" => "fr", "browser_locales" => ["de", "fr"]} =
             LocalePlug.live_session_data(conn)
  end

  test "a pick remembered in the session is the pick when the URL names none", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{chosen_locale: "it"})
      |> Map.put(:params, %{})
      |> put_req_header("accept-language", "de")
      |> LocalePlug.call([])

    assert conn.assigns.locale_choice == "it"
    assert conn.assigns.browser_locales == ["de"]
  end

  test "no pick without a ?locale= or a remembered choice", %{conn: conn} do
    conn =
      conn
      |> Map.put(:params, %{})
      |> fetch_session()
      |> put_req_header("accept-language", "de")
      |> LocalePlug.call([])

    assert conn.assigns.locale_choice == nil
    refute Map.has_key?(LocalePlug.live_session_data(conn), "locale_choice")
  end
end
