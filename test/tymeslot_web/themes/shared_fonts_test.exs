defmodule TymeslotWeb.Themes.SharedFontsTest do
  @moduledoc """
  Pins the self-hosted fonts behind the booking themes' font stacks
  (`assets/css/scheduling/shared/fonts.css`): every `url()` there names a woff2
  file that ships under `priv/static/fonts/` and is served, every shipped font
  file is declared, each family carries its licence, and every font id a theme
  or the font option group can pick has a body and a heading stack.
  """

  # These tests guard shipped assets and their CSS, not application code, so
  # there is no Tymeslot function for them to call.
  # credo:disable-for-this-file Jump.CredoChecks.VacuousTest

  use TymeslotWeb.ConnCase, async: true

  alias Tymeslot.ThemeCustomizations.Presets.Fonts
  alias TymeslotWeb.ThemeTestMatrix

  @moduletag :themes
  @moduletag :unit

  @entry_css "assets/css/scheduling/shared/entry.css"
  @dashboard_css "assets/css/app.css"
  @fonts_css "assets/css/scheduling/shared/fonts.css"
  @fonts_dir "priv/static/fonts"

  @families ~w(inter ibm-plex-sans source-serif-4 source-sans-3 lora fraunces)
  # Fraunces has no Cyrillic glyphs, so its Cyrillic falls to the system serif.
  @cyrillic_families @families -- ["fraunces"]
  @font_files length(@families) * 2 + length(@cyrillic_families)
  @font_ids Map.keys(Fonts.all())

  defp font_urls do
    ~r/url\("([^"]+)"\)/
    |> Regex.scan(File.read!(@fonts_css), capture: :all_but_first)
    |> Enum.map(fn [url] -> url end)
  end

  test "the shared entry imports the font rules" do
    assert File.read!(@entry_css) =~ ~s(@import "./fonts.css";)
  end

  # The font picker shows each choice's name in its heading stack.
  test "the dashboard imports the font rules, so the font picker shows each face" do
    assert File.read!(@dashboard_css) =~ ~s(@import "./scheduling/shared/fonts.css";)
  end

  test "every url() names a woff2 file under /fonts/ that ships" do
    urls = font_urls()

    # Latin and Latin Extended for each family, plus Cyrillic where it exists.
    assert length(urls) == @font_files

    assert Enum.reject(urls, fn url ->
             String.starts_with?(url, "/fonts/") and String.ends_with?(url, ".woff2") and
               File.regular?(Path.join("priv/static", url))
           end) == []
  end

  test "every shipped font file is declared, so nothing ships unused" do
    shipped =
      "#{@fonts_dir}/*.woff2"
      |> Path.wildcard()
      |> Enum.map(&("/fonts/" <> Path.basename(&1)))
      |> Enum.sort()

    assert shipped == Enum.sort(font_urls())
  end

  test "every font file is a real woff2, of one subset's size" do
    files = Path.wildcard("#{@fonts_dir}/*.woff2")
    assert length(files) == @font_files

    assert Enum.reject(files, fn file ->
             match?(<<"wOF2", _rest::binary>>, File.read!(file)) and
               File.stat!(file).size < 100_000
           end) == []
  end

  # Ukrainian and Russian text would otherwise drop to a system face beside
  # the theme's Latin letters.
  test "every family with a Cyrillic subset declares it for the Cyrillic block" do
    css = File.read!(@fonts_css)

    assert Enum.reject(@cyrillic_families, fn family ->
             css =~
               ~r{src: url\("/fonts/#{family}-cyrillic-wght-normal\.woff2"\) format\("woff2"\);\s*unicode-range: U\+0301, U\+0400-045F,}
           end) == []

    refute css =~ "fraunces-cyrillic"
  end

  test "every family carries its licence" do
    assert Enum.reject(@families, fn family ->
             path = Path.join(@fonts_dir, "OFL-#{family}.txt")
             File.regular?(path) and File.read!(path) =~ "SIL Open Font License"
           end) == []
  end

  test "every font id has a body stack and a heading stack" do
    css = File.read!(@fonts_css)

    assert Enum.reject(@font_ids, fn id ->
             css =~ "--font-stack-#{id}:" and css =~ "--font-heading-#{id}:"
           end) == []
  end

  # A theme that names a family itself gets the system font wherever that
  # family is not installed, silently: Quill and Rhythm asked for 'Inter' for
  # years with nothing loading it.
  test "every shipped theme's font family is one of the shared stacks" do
    families =
      for path <- Path.wildcard("assets/css/scheduling/themes/*/modules/variables.css") do
        [_match, value] = Regex.run(~r/--theme-font-family:\s*([^;]+);/, File.read!(path))
        {path, String.trim(value)}
      end

    # One stylesheet per shipped theme, so none is skipped by a typo in its path.
    assert length(families) == length(ThemeTestMatrix.all())

    assert Enum.reject(families, fn {_path, value} ->
             case Regex.run(~r/^var\(--font-stack-([a-z]+)\)$/, value) do
               [_match, id] -> id in @font_ids
               nil -> false
             end
           end) == []
  end

  test "the endpoint serves the font files", %{conn: conn} do
    conn = get(conn, "/fonts/inter-latin-wght-normal.woff2")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "font/woff2"
  end
end
