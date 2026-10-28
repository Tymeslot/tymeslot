defmodule TymeslotWeb.Components.CoreComponents.IconSource do
  @moduledoc """
  Compile-time reader for a directory of single-colour SVG icons.

  Every icon set `<.icon>` resolves (the vendored Heroicons, Core's own
  `priv/icons`, and any set an app layered on top keeps in its own `priv`) is
  read through here into a map baked into the calling module, so all of them
  render through the one `CoreComponents.Icons` renderer with the same
  attributes.

  Only the root attributes that decide how an icon paints are kept (`viewBox`,
  `fill`, `stroke` and the stroke styling); the rest (`xmlns`, `aria-hidden`,
  `data-slot`, any `class`) is supplied by the renderer, so a stray attribute
  in a source file cannot leak into the page.
  """

  @painting_attrs ~w(viewBox fill stroke stroke-width stroke-linecap stroke-linejoin)

  @type icon :: %{attrs: [{String.t(), String.t()}], body: String.t(), size: pos_integer()}

  @doc """
  Reads every `*.svg` in `dir` into a `name => icon` map.

  The name is `prefix` followed by the file's basename. `size` is the intrinsic
  width and height the icon renders at when no size class is given; it
  defaults to the `viewBox` width.
  """
  @spec load(Path.t(), keyword()) :: %{String.t() => icon()}
  def load(dir, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")
    suffix = Keyword.get(opts, :suffix, "")
    size = Keyword.get(opts, :size)

    for file <- files(dir), into: %{} do
      name = prefix <> Path.basename(file, ".svg") <> suffix
      {name, parse!(File.read!(Path.join(dir, file)), file, size)}
    end
  end

  @doc """
  The sorted `*.svg` file names in `dir` (empty when it does not exist).

  A module that loads `dir` keeps this as its fingerprint and compares it in
  `__mix_recompile__?/0`, so adding or removing an icon file recompiles it;
  `@external_resource` alone only notices edits to files it already knew.
  """
  @spec files(Path.t()) :: [String.t()]
  def files(dir) do
    if File.dir?(dir) do
      dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".svg")) |> Enum.sort()
    else
      []
    end
  end

  defp parse!(content, file, size) do
    with [_match, root, inner] <- Regex.run(~r/<svg([^>]*)>(.*)<\/svg>/s, content),
         attrs = painting_attrs(root),
         {"viewBox", view_box} <- List.keyfind(attrs, "viewBox", 0) do
      %{attrs: attrs, body: String.trim(inner), size: size || view_box_width(view_box)}
    else
      _invalid -> raise ArgumentError, "#{file} is not an <svg> with a viewBox"
    end
  end

  defp painting_attrs(root) do
    for [_match, key, value] <- Regex.scan(~r/([\w-]+)="([^"]*)"/, root),
        key in @painting_attrs,
        do: {key, value}
  end

  defp view_box_width(view_box) do
    [_min_x, _min_y, width, _height] = String.split(view_box)
    width |> Float.parse() |> elem(0) |> round()
  end
end
