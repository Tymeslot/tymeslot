defmodule TymeslotWeb.Themes.Shared.FontPreloadTest do
  @moduledoc """
  The booking page preloads the font files its text is set in, so the face is
  there before the first layout and nothing jumps when it swaps in: the files
  follow the font ids' stacks in `fonts.css` and the page's locale, and every
  shipped theme's page preloads exactly the families its stylesheet sets its
  text in, or the font its customisation chose.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.Factory, only: [insert: 2]

  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations.Presets.Fonts
  alias TymeslotWeb.Themes.Shared.FontPreload
  alias TymeslotWeb.ThemeTestMatrix

  @fonts_css "assets/css/scheduling/shared/fonts.css"

  # The file stem fonts.css gives each family name its stacks use.
  @stems %{
    "Inter Variable" => "inter",
    "IBM Plex Sans Variable" => "ibm-plex-sans",
    "Source Serif 4 Variable" => "source-serif-4",
    "Source Sans 3 Variable" => "source-sans-3",
    "Lora Variable" => "lora",
    "Fraunces Variable" => "fraunces"
  }

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  # The families a stack names, following `var(--font-stack-<id>)` references.
  defp stack_families(css, name) do
    [_match, value] = Regex.run(~r/#{Regex.escape(name)}:\s*([^;]+);/, css)

    case Regex.run(~r/^var\((--font-stack-[a-z]+)\)$/, String.trim(value)) do
      [_match, other] -> stack_families(css, other)
      nil -> for {family, stem} <- @stems, String.contains?(value, ~s("#{family}")), do: stem
    end
  end

  describe "families/1" do
    test "names the downloaded families of each font id's body and heading stacks" do
      css = File.read!(@fonts_css)
      ids = Map.keys(Fonts.all())
      assert "inter" in ids

      assert Enum.reject(ids, fn id ->
               expected =
                 Enum.uniq(
                   stack_families(css, "--font-stack-#{id}") ++
                     stack_families(css, "--font-heading-#{id}")
                 )

               Enum.sort(FontPreload.families(id)) == Enum.sort(expected)
             end) == []
    end
  end

  describe "files/2" do
    test "preloads the Latin subset for a Latin-1 locale, and nothing for the system fonts" do
      assert FontPreload.files("classic", "de") == [
               "/fonts/inter-latin-wght-normal.woff2",
               "/fonts/source-serif-4-latin-wght-normal.woff2"
             ]

      assert FontPreload.files("system", "de") == []
      assert FontPreload.files(nil, "en") == []
    end

    test "adds Latin Extended for Czech and Polish, and Cyrillic for Ukrainian where a family has it" do
      assert "/fonts/inter-latin-ext-wght-normal.woff2" in FontPreload.files("inter", "pl")

      assert FontPreload.files("editorial", "uk") == [
               "/fonts/inter-latin-wght-normal.woff2",
               "/fonts/inter-cyrillic-wght-normal.woff2",
               "/fonts/fraunces-latin-wght-normal.woff2"
             ]
    end

    test "names only files that ship" do
      files =
        for id <- Map.keys(Fonts.all()),
            locale <- ~w(en cs uk),
            file <- FontPreload.files(id, locale),
            uniq: true,
            do: file

      assert files != []
      assert Enum.reject(files, &File.regular?(Path.join("priv/static", &1))) == []
    end
  end

  # The stylesheet's font, which the page must preload when nothing else was chosen.
  defp stylesheet_font(key) do
    css = File.read!("assets/css/scheduling/themes/#{key}/modules/variables.css")
    [_match, id] = Regex.run(~r/--theme-font-family:\s*var\(--font-stack-([a-z]+)\);/, css)
    id
  end

  defp preloads(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(link[rel="preload"][as="font"]))
    |> Enum.flat_map(&Floki.attribute(&1, "href"))
  end

  for %{id: theme_id, key: key} <- ThemeTestMatrix.all() do
    test "the #{key} page preloads the fonts its stylesheet sets its text in", %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme_id), "fonts-#{unquote(key)}", "UTC")

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      assert preloads(html) == FontPreload.files(stylesheet_font(unquote(key)), "en")
    end
  end

  test "a theme with a font option preloads the font the organiser chose", %{conn: conn} do
    %{id: theme_id} = Enum.find(ThemeTestMatrix.all(), &(&1.key == :paper))
    %{profile: profile} = seed_booking_account(theme_id, "fonts-chosen", "UTC")

    insert(:theme_customization,
      profile: profile,
      theme_id: theme_id,
      settings: %{"font" => "plex"}
    )

    {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

    assert preloads(html) == ["/fonts/ibm-plex-sans-latin-wght-normal.woff2"]
  end
end
