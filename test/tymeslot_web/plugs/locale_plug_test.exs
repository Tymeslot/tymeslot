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
        |> put_session(:locale, "de")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
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
        |> put_session(:locale, "en")
        |> LocalePlug.call([])

      # de can only come from the query param, so it winning proves priority.
      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
    end

    test "prioritizes query parameter over Accept-Language header", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "de"})
        |> fetch_session()
        |> put_req_header("accept-language", "en-US")
        |> LocalePlug.call([])

      # de comes only from the query param; the header would resolve to en.
      assert conn.assigns.locale == "de"
    end

    test "prioritizes session over Accept-Language header", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_session(:locale, "de")
        |> put_req_header("accept-language", "en")
        |> LocalePlug.call([])

      # de comes only from the session; the header would resolve to en.
      assert conn.assigns.locale == "de"
    end

    test "an unsupported query parameter falls through to the valid session locale instead of overwriting it",
         %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "es"})
        |> fetch_session()
        |> put_session(:locale, "de")
        |> LocalePlug.call([])

      # es is a shape-valid but unsupported param — it must not short-circuit
      # past the valid "de" session locale and be coerced to the default.
      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
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
      # es has the highest quality but is unsupported, so it is skipped in favour
      # of the highest-quality supported language (de over en).
      conn =
        conn
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_req_header("accept-language", "es;q=0.9,de;q=0.8,en;q=0.7")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
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

  describe "path-derived locale (:path_locale assign)" do
    test "wins over the query parameter, session, and header", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "en"})
        |> fetch_session()
        |> put_session(:locale, "en")
        |> put_req_header("accept-language", "en")
        |> assign(:path_locale, "de")
        |> LocalePlug.call([])

      # de comes only from the path assign; every other source says en.
      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "wins over the saved user locale even with prefer_user_locale", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> fetch_session()
        |> assign(:current_user, %{locale: "en"})
        |> assign(:path_locale, "de")
        |> LocalePlug.call(prefer_user_locale: true)

      # The URL is the most explicit statement of intent — it beats the
      # account preference on pages that carry a locale prefix.
      assert conn.assigns.locale == "de"
    end

    test "an unsupported path locale falls through to the next source", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> fetch_session()
        |> put_session(:locale, "de")
        |> assign(:path_locale, "xx")
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
        |> put_req_header("accept-language", "en")
        |> LocalePlug.call(prefer_user_locale: true)

      # de comes only from the saved user preference; the header would give en.
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
        |> assign(:current_user, %{locale: "en"})
        |> put_req_header("accept-language", "de")
        |> LocalePlug.call([])

      # Without prefer_user_locale, the chain ignores the user's en and falls
      # through to the header's de.
      assert conn.assigns.locale == "de"
    end

    test "falls through the normal chain when the user locale is nil", %{conn: _conn} do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> fetch_session()
        |> assign(:current_user, %{locale: nil})
        |> put_req_header("accept-language", "de")
        |> LocalePlug.call(prefer_user_locale: true)

      assert conn.assigns.locale == "de"
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
        |> put_req_header("accept-language", "de")
        |> LocalePlug.call([])

      assert get_session(conn, :locale) == "de"
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

  describe "locale reaches every Gettext backend" do
    # LocalePlug must set the locale globally (`Gettext.put_locale/1`), not
    # per-backend (`Gettext.put_locale/2`), so a second backend — e.g. the
    # SaaS marketing backend, which Core cannot reference directly — still
    # resolves the chosen locale. `TymeslotWeb.SecondGettextBackendForTest`
    # stands in for that second backend. Regression test for the case where
    # a language switcher appears to work but silently does nothing outside
    # the backend that was written to directly.
    test "a second backend resolves the same locale set by LocalePlug", %{conn: _conn} do
      _conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "de"})
        |> fetch_session()
        |> LocalePlug.call([])

      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
      assert Gettext.get_locale(TymeslotWeb.SecondGettextBackendForTest) == "de"
    end
  end
end
