defmodule TymeslotWeb.Themes.Shared.FontPreload do
  @moduledoc """
  Preloads the web fonts a booking page draws its text in.

  The faces in `scheduling/shared/fonts.css` are `font-display: swap`, and a
  browser only asks for a face once the theme's stylesheet has been parsed and
  some text laid out in its family. Until it arrives the text is set in the
  system fallback, which is wider than Inter: a heading that fits one line in
  Inter wraps onto two, so when the font swaps in, everything below it jumps
  up (Rhythm's landing measured a cumulative layout shift of up to 0.08 on a
  phone, with no input). A `<link rel="preload">` in the scheduling root
  layout's `<head>` (`TymeslotWeb.Layouts`) starts the download alongside
  the stylesheet, so the face is there before the first layout and nothing
  swaps. The font is the one the customisation chose, else the theme's own
  (`font/0`, the `:font` option of `use TymeslotWeb.Themes.Core.Theme`).

  `links/1` takes a font id (`Presets.Fonts`) and the page's locale, and
  preloads the subsets of that id's body and heading families the locale's
  text needs: Latin always (digits, punctuation and Western European
  letters), plus Latin Extended for Czech and Polish, or Cyrillic for
  Ukrainian where the family has it. `@families` mirrors the stacks in
  `fonts.css`, which `shared_fonts_test.exs` holds it to; the system ids name
  no family and preload nothing.

  The paths go through `static_path/2`, so in production they are the
  digested names `phx.digest` also writes into the stylesheet's `url()`s, and
  the browser takes the preloaded file for the face.
  """
  use Phoenix.Component

  alias Phoenix.VerifiedRoutes
  alias TymeslotWeb.Endpoint

  # Font id => the families its body and heading stacks name, in that order.
  @families %{
    "system" => [],
    "quiet" => [],
    "inter" => ["inter"],
    "plex" => ["ibm-plex-sans"],
    "classic" => ["inter", "source-serif-4"],
    "literary" => ["source-sans-3", "lora"],
    "editorial" => ["inter", "fraunces"]
  }

  # Fraunces ships no Cyrillic subset (see fonts.css).
  @no_cyrillic ["fraunces"]

  @doc "The families a font id's stacks name; none for an unknown id."
  @spec families(String.t() | nil) :: [String.t()]
  def families(font), do: Map.get(@families, font, [])

  @doc "The font files, under `/fonts/`, a page in `font` and `locale` needs first."
  @spec files(String.t() | nil, String.t() | nil) :: [String.t()]
  def files(font, locale) do
    for family <- families(font),
        subset <- subsets(locale),
        subset != "cyrillic" or family not in @no_cyrillic do
      "/fonts/#{family}-#{subset}-wght-normal.woff2"
    end
  end

  defp subsets(locale) when locale in ["cs", "pl"], do: ["latin", "latin-ext"]
  defp subsets("uk"), do: ["latin", "cyrillic"]
  defp subsets(_locale), do: ["latin"]

  attr :font, :string, default: nil, doc: "a `Presets.Fonts` id; nil preloads nothing"
  attr :locale, :string, default: nil

  @doc "One `<link rel=\"preload\">` per font file the page's text needs first."
  @spec links(map()) :: Phoenix.LiveView.Rendered.t()
  def links(assigns) do
    assigns =
      assign(assigns,
        hrefs:
          Enum.map(files(assigns.font, assigns.locale), &VerifiedRoutes.static_path(Endpoint, &1))
      )

    ~H"""
    <link
      :for={href <- @hrefs}
      rel="preload"
      href={href}
      as="font"
      type="font/woff2"
      crossorigin="anonymous"
    />
    """
  end
end
