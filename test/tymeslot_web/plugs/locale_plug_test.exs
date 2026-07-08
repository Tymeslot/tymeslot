defmodule TymeslotWeb.Plugs.LocalePlugTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  alias TymeslotWeb.Plugs.LocalePlug

  describe "locale detection" do
    test "uses query parameter when provided", %{conn: conn} do
      conn = conn |> Map.put(:params, %{}) |> fetch_session() |> LocalePlug.call([])
      assert conn.assigns.locale == "en"

      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "de"})
        |> fetch_session()
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "uses session locale when no query parameter", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_session(:locale, "uk")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "uk"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "uk"
    end

    test "parses Accept-Language header when no session or query param", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "de-DE,de;q=0.9,en;q=0.8")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
    end

    test "falls back to default locale when nothing is set", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> LocalePlug.call([])

      assert conn.assigns.locale == "en"
      assert get_session(conn, :locale) == "en"
    end

    test "prioritizes query parameter over session", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "de"})
        |> fetch_session()
        |> put_session(:locale, "uk")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
    end

    test "prioritizes query parameter over Accept-Language header", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "uk"})
        |> fetch_session()
        |> put_req_header("accept-language", "de-DE")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "uk"
    end

    test "prioritizes session over Accept-Language header", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_session(:locale, "de")
        |> put_req_header("accept-language", "uk")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
    end
  end

  describe "Accept-Language header parsing" do
    test "handles simple language code", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "de")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
    end

    test "handles language with region code", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "de-DE")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
    end

    test "handles multiple languages with quality scores", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "uk;q=0.9,de;q=0.8,en;q=0.7")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "uk"
    end

    test "picks first supported language from list", %{conn: conn} do
      # es is not supported, so should fall to de
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "es,de,en")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
    end

    test "handles malformed Accept-Language gracefully", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "invalid;format;;;")
        |> LocalePlug.call([])

      # Should fall back to default
      assert conn.assigns.locale == "en"
    end

    test "rejects negative quality scores", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "de;q=-1.0,en;q=0.5")
        |> LocalePlug.call([])

      # Negative quality should be rejected, should use en
      assert conn.assigns.locale == "en"
    end

    test "rejects quality scores greater than 1.0", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "de;q=999.0,en;q=0.5")
        |> LocalePlug.call([])

      # Invalid quality should be rejected, should use en
      assert conn.assigns.locale == "en"
    end

    test "handles extremely long Accept-Language header", %{conn: conn} do
      # Create a header longer than max length (1000 bytes)
      long_header = String.duplicate("en-US,", 200)

      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", long_header)
        |> LocalePlug.call([])

      # Should fall back to default when header is too long
      assert conn.assigns.locale == "en"
    end

    test "handles invalid UTF-8 in Accept-Language header", %{conn: conn} do
      # Invalid UTF-8 sequence
      invalid_utf8 = <<0xFF, 0xFE, 0xFD, "de">>

      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", invalid_utf8)
        |> LocalePlug.call([])

      # Should fall back to default
      assert conn.assigns.locale == "en"
    end

    test "limits number of language tags to prevent DoS", %{conn: conn} do
      # Create header with many tags (more than max count of 20)
      many_tags = Enum.map_join(1..50, ",", fn i -> "lang#{i}" end)

      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", many_tags <> ",de")
        |> LocalePlug.call([])

      # Should still work but only process first 20 tags
      # Since none of the first tags are supported, should fall back to default
      assert conn.assigns.locale == "en"
    end

    test "rejects extremely long individual language tags", %{conn: conn} do
      # Create a single tag longer than 100 bytes
      long_tag = String.duplicate("x", 150)

      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "#{long_tag},de")
        |> LocalePlug.call([])

      # Should skip the long tag and use de
      assert conn.assigns.locale == "de"
    end

    test "handles Unicode bidirectional override in Accept-Language", %{conn: conn} do
      # U+202E in header
      header_with_bidi = "d\u202Ee"

      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", header_with_bidi)
        |> LocalePlug.call([])

      # Should strip control characters and recognize "de"
      assert conn.assigns.locale == "de"
    end
  end

  describe "locale validation" do
    test "rejects unsupported locale codes", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "es"})
        |> fetch_session()
        |> LocalePlug.call([])

      # Should fall back to default when unsupported
      assert conn.assigns.locale == "en"
    end

    test "handles empty locale string", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => ""})
        |> fetch_session()
        |> LocalePlug.call([])

      assert conn.assigns.locale == "en"
    end

    test "handles nil locale", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => nil})
        |> fetch_session()
        |> LocalePlug.call([])

      assert conn.assigns.locale == "en"
    end

    test "truncates extremely long locale strings", %{conn: _conn} do
      # Create a locale string longer than max length
      long_locale = String.duplicate("a", 100)

      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => long_locale})
        |> fetch_session()
        |> LocalePlug.call([])

      # Should fall back to default since truncated value won't match supported locales
      assert conn.assigns.locale == "en"
    end

    test "handles invalid UTF-8 in locale param", %{conn: _conn} do
      # Invalid UTF-8 sequence
      invalid_utf8 = <<0xFF, 0xFE, 0xFD>>

      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => invalid_utf8})
        |> fetch_session()
        |> LocalePlug.call([])

      assert conn.assigns.locale == "en"
    end

    test "rejects path traversal attempts", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "../de"})
        |> fetch_session()
        |> LocalePlug.call([])

      # Path components should be stripped, leaving just "de"
      assert conn.assigns.locale == "de"
    end

    test "removes Unicode bidirectional override characters", %{conn: _conn} do
      # U+202E is right-to-left override
      locale_with_bidi = "d\u202Ee"

      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => locale_with_bidi})
        |> fetch_session()
        |> LocalePlug.call([])

      # Should strip the control character and result in "de"
      assert conn.assigns.locale == "de"
    end

    test "removes control characters", %{conn: _conn} do
      locale_with_controls = "d\u0000e\u001F"

      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => locale_with_controls})
        |> fetch_session()
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
    end
  end

  describe "user locale preference (prefer_user_locale)" do
    test "honours the current user's saved locale over the Accept-Language header", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> fetch_session()
        |> assign(:current_user, %{locale: "de"})
        |> put_req_header("accept-language", "uk")
        |> LocalePlug.call(prefer_user_locale: true)

      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "ignores the user locale when the option is not set", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> fetch_session()
        |> assign(:current_user, %{locale: "de"})
        |> put_req_header("accept-language", "uk")
        |> LocalePlug.call([])

      # Without prefer_user_locale, the chain falls through to the header.
      assert conn.assigns.locale == "uk"
    end

    test "falls through the normal chain when the user locale is nil", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> fetch_session()
        |> assign(:current_user, %{locale: nil})
        |> put_req_header("accept-language", "uk")
        |> LocalePlug.call(prefer_user_locale: true)

      assert conn.assigns.locale == "uk"
    end
  end

  describe "locale persistence" do
    test "persists selected locale to session", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "de"})
        |> fetch_session()
        |> LocalePlug.call([])

      assert get_session(conn, :locale) == "de"
    end

    test "persists detected locale from header to session", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "uk")
        |> LocalePlug.call([])

      assert get_session(conn, :locale) == "uk"
    end

    test "updates Gettext locale for current process", %{conn: _conn} do
      _conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "de"})
        |> fetch_session()
        |> LocalePlug.call([])

      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end
  end
end
