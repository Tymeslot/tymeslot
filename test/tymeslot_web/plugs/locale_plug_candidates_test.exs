defmodule TymeslotWeb.Plugs.LocalePlugCandidatesTest do
  @moduledoc """
  `LocalePlug` carries the visitor's own acceptable locales, highest priority
  first, to the LiveView session, so a booking page offering only some
  languages can pick the first it offers.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :i18n
  @moduletag :plugs

  alias TymeslotWeb.Plugs.LocalePlug

  test "the choice, then the header's tags, normalised, acceptable and without duplicates",
       %{conn: conn} do
    conn =
      conn
      |> Map.put(:params, %{"locale" => "fr"})
      |> fetch_session()
      |> put_req_header("accept-language", "xx, de-AT, fr;q=0.5, it;q=0")
      |> LocalePlug.call([])

    assert conn.assigns.locale_candidates == ["fr", "de"]
    assert LocalePlug.live_session_data(conn)["locale_candidates"] == ["fr", "de"]
  end
end
