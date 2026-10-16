defmodule Tymeslot.ThemeCustomizations.Options.Background do
  @moduledoc """
  The background option: a gradient preset, a solid colour, a preset or
  uploaded image, or a preset or uploaded video. Stored as the `background_*`
  settings.

  An `OptionGroup`: a spec lists it as `%{key: :background, module:
  Options.Background, kinds: [...]}`, naming the kinds its theme offers, and
  the preset ids it offers of each: `gradients:`, `images:`, `videos:`, in
  picker order. A preset outside them is refused. `changeset/3` and
  `changes/3` refuse the rest, so no write path can store a background the
  theme cannot show, and `asset_fields/1` offers only the uploads of offered
  kinds. A `preset:` value must be one of the group's; any other image or
  video value is an upload and needs its stored path. `media/2` hands the
  resolved descriptor to `Tokens.media` as `:background`, and `tokens/4` adds
  `--theme-background` to the page's variables, so the group is declared after
  the palette whose canvas it may show.
  """

  import Ecto.Changeset

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.ThemeCustomizations.Validation
  alias Tymeslot.Utils.Colour

  @behaviour OptionGroup

  @types %{
    background_type: :string,
    background_value: :string,
    background_image_path: :string,
    background_video_path: :string
  }
  @fields Map.keys(@types)
  @asset_fields [background_image_path: :image, background_video_path: :video]
  @preset_lists %{gradient: :gradients, image: :images, video: :videos}
  @kinds_by_type %{
    "gradient" => :gradient,
    "color" => :color,
    "image" => :image,
    "video" => :video
  }

  @preset_image_dir "/images/themes/backgrounds/"
  @preset_video_dir "/videos/backgrounds/"
  @poster_dir "/images/ui/posters/"
  @preset_video_variants [
    {"-desktop.webm", "video/webm", "(min-width: 1024px)"},
    {"-desktop.mp4", "video/mp4", "(min-width: 1024px)"},
    {"-mobile.mp4", "video/mp4", "(max-width: 768px)"},
    {"-low.mp4", "video/mp4", "(max-width: 480px)"},
    {"-original.mp4", "video/mp4", nil}
  ]

  @typedoc "One `<source>` of a background video, in the order the browser should try them."
  @type video_source :: %{src: String.t(), type: String.t(), media: String.t() | nil}

  @typedoc "A resolved, render-ready background. Every path in it is already safe to emit."
  @type descriptor ::
          %{kind: :gradient, css: String.t()}
          | %{kind: :color, color: String.t()}
          | %{kind: :image, url: String.t()}
          | %{kind: :video, sources: [video_source()], poster: String.t() | nil}

  @typedoc """
  A background group: the kinds the theme offers, and for each preset kind
  the preset ids it offers, in picker order. A missing list offers none.
  """
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:kinds) => [Spec.background_kind()],
          optional(:gradients) => [String.t()],
          optional(:images) => [String.t()],
          optional(:videos) => [String.t()],
          optional(atom()) => term()
        }

  @doc "The settings the background stores, with their Ecto types."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts and validates the background settings against the kinds the group offers."
  @impl OptionGroup
  def changeset(changeset, attrs, %{kinds: kinds} = group) do
    changeset
    |> cast(attrs, @fields)
    |> validate_required([:background_type])
    |> validate_inclusion(:background_type, Map.keys(@kinds_by_type))
    |> validate_supported(kinds)
    |> validate_value(group)
  end

  @doc "The upload settings of the kinds the group offers, and what each stores."
  @impl OptionGroup
  def asset_fields(%{kinds: kinds}),
    do: Enum.filter(@asset_fields, fn {_field, kind} -> kind in kinds end)

  @doc """
  The changes choosing a background makes, or `:error` for a kind the group
  does not offer. An upload survives only when the new background is that
  same kind chosen as `"custom"`; every other choice (a preset of either kind,
  a gradient, or a colour) drops both uploads, so a stored file is never
  orphaned by a change that stops naming it.
  """
  @impl OptionGroup
  def changes(kind, value, %{kinds: kinds}) do
    if kind in Enum.map(kinds, &Atom.to_string/1) do
      {:ok,
       Map.merge(
         %{"background_type" => kind, "background_value" => value},
         cleared_uploads(kind, value)
       )}
    else
      :error
    end
  end

  @doc """
  The changes an upload into one of the background's asset fields makes: the
  upload becomes the custom background of its kind, and the background's
  other upload is dropped, so the save deletes its file.
  """
  @impl OptionGroup
  @spec upload_changes(atom(), String.t(), group()) :: map()
  def upload_changes(field, path, group) do
    fields = asset_fields(group)
    kind = Keyword.fetch!(fields, field)

    fields
    |> Keyword.delete(field)
    |> Map.new(fn {other, _kind} -> {Atom.to_string(other), nil} end)
    |> Map.merge(%{
      "background_type" => Atom.to_string(kind),
      "background_value" => "custom",
      Atom.to_string(field) => path
    })
  end

  @doc "The group's presets of one kind as `{id, preset}`, in the group's order."
  @spec presets(group(), :gradient | :image | :video) :: [{String.t(), Presets.preset()}]
  def presets(group, kind), do: Presets.take(kind, preset_ids(group, kind))

  @doc """
  Resolves the stored background into a descriptor the theme wrapper renders.

  Every path in it is already safe to emit. Returns `nil` when the settings
  name nothing that resolves (an unknown preset, an image kind with neither
  upload nor preset); the wrapper then falls back to the theme's own
  background.
  """
  @spec descriptor(Spec.settings()) :: descriptor() | nil
  def descriptor(%{"background_type" => "gradient", "background_value" => id}) do
    case Presets.find_preset_by_id(:gradient, id) do
      %{value: css} -> %{kind: :gradient, css: css}
      nil -> nil
    end
  end

  def descriptor(%{"background_type" => "color", "background_value" => value}) do
    case Colour.cast_hex(value) do
      {:ok, hex} -> %{kind: :color, color: hex}
      :error -> nil
    end
  end

  def descriptor(%{"background_type" => "image", "background_image_path" => path})
      when is_binary(path) and path != "" do
    %{kind: :image, url: "/uploads/" <> Validation.sanitize_path(path)}
  end

  def descriptor(%{"background_type" => "image"} = settings) do
    case Presets.find_preset_by_id(:image, settings["background_value"]) do
      %{file: file} -> %{kind: :image, url: preset_image_url(file)}
      nil -> nil
    end
  end

  def descriptor(%{"background_type" => "video"} = settings) do
    %{
      kind: :video,
      sources: video_sources(settings),
      poster: poster(settings["background_value"])
    }
  end

  def descriptor(_settings), do: nil

  @doc "The background's contribution to `Tokens.media`: its descriptor, under `:background`."
  @impl OptionGroup
  @spec media(Spec.settings(), group()) :: %{background: descriptor() | nil}
  def media(settings, _group), do: %{background: descriptor(settings)}

  @doc """
  The background's part of a spec's tokens (`OptionGroup.tokens/4`): its
  `--theme-background` (`vars/2`), from its own descriptor and the canvas the
  groups before it produced. The dark set is left as it was.
  """
  @impl OptionGroup
  @spec tokens(Spec.settings(), Spec.overrides(), OptionGroup.token_sets(), group()) ::
          OptionGroup.token_sets()
  def tokens(settings, _overrides, %{vars: page_vars} = acc, group) do
    %{background: descriptor} = media(settings, group)
    %{acc | vars: Map.merge(page_vars, vars(descriptor, page_vars))}
  end

  @doc """
  The public URL of a preset image file, as booking pages and the dashboard
  picker both load it.
  """
  @spec preset_image_url(String.t()) :: String.t()
  def preset_image_url(file) when is_binary(file), do: @preset_image_dir <> file

  @doc """
  The `--theme-background` custom property for a descriptor.

  Gradients and colours are the background itself. Behind an image or a video
  (or when nothing resolved) the page shows the palette's canvas colour, as it
  always has; with no palette either, the theme's own default stands.
  """
  @spec vars(descriptor() | nil, Tokens.css_vars()) :: Tokens.css_vars()
  def vars(%{kind: :gradient, css: css}, _palette_vars), do: %{"--theme-background" => css}
  def vars(%{kind: :color, color: hex}, _palette_vars), do: %{"--theme-background" => hex}

  def vars(_media_or_nil, %{"--theme-canvas" => _canvas}),
    do: %{"--theme-background" => "var(--theme-canvas)"}

  def vars(_media_or_nil, _palette_vars), do: %{}

  defp cleared_uploads("image", "custom"), do: %{"background_video_path" => nil}
  defp cleared_uploads("video", "custom"), do: %{"background_image_path" => nil}

  defp cleared_uploads(_kind, _value),
    do: %{"background_image_path" => nil, "background_video_path" => nil}

  defp video_sources(%{"background_video_path" => path}) when is_binary(path) and path != "" do
    sanitized = Validation.sanitize_path(path)
    base = Path.rootname(sanitized)

    variants =
      Enum.map(Transcoder.variant_definitions(), fn variant ->
        %{src: "/uploads/" <> base <> variant.suffix, type: variant.type, media: variant.media}
      end)

    # The original upload is always the last fallback.
    variants ++ [%{src: "/uploads/" <> sanitized, type: "video/mp4", media: nil}]
  end

  defp video_sources(settings) do
    case Presets.find_preset_by_id(:video, settings["background_value"]) do
      %{file: file} -> preset_sources(file)
      nil -> []
    end
  end

  # A preset ships five sizes, tried in this order; the original is the last
  # fallback.
  defp preset_sources(desktop_file) do
    base =
      desktop_file
      |> String.replace("-desktop.mp4", "")
      |> String.replace("-desktop.webm", "")

    Enum.map(@preset_video_variants, fn {suffix, type, media} ->
      %{src: @preset_video_dir <> base <> suffix, type: type, media: media}
    end)
  end

  defp poster(value) do
    case Presets.find_preset_by_id(:video, value) do
      %{poster: poster} when is_binary(poster) -> @poster_dir <> poster
      _other -> nil
    end
  end

  defp validate_supported(changeset, kinds) do
    kind = Map.get(@kinds_by_type, get_field(changeset, :background_type))

    if kind && kind not in kinds do
      add_error(changeset, :background_type, "is not supported by this theme")
    else
      changeset
    end
  end

  defp validate_value(changeset, group) do
    case get_field(changeset, :background_type) do
      "gradient" ->
        validate_preset(
          changeset,
          preset_ids(group, :gradient),
          "must be a valid gradient preset"
        )

      "color" ->
        cast_colour(changeset)

      "image" ->
        validate_media(changeset, preset_ids(group, :image), :background_image_path, "image")

      "video" ->
        validate_media(changeset, preset_ids(group, :video), :background_video_path, "video")

      _invalid_type ->
        changeset
    end
  end

  defp preset_ids(group, kind), do: Map.get(group, Map.fetch!(@preset_lists, kind), [])

  defp validate_preset(changeset, ids, message) do
    if get_field(changeset, :background_value) in ids,
      do: changeset,
      else: add_error(changeset, :background_value, message)
  end

  defp cast_colour(changeset) do
    case Colour.cast_hex(get_field(changeset, :background_value)) do
      {:ok, hex} -> put_change(changeset, :background_value, hex)
      :error -> add_error(changeset, :background_value, "must be a valid hex color")
    end
  end

  defp validate_media(changeset, ids, path_field, label) do
    value = get_field(changeset, :background_value)

    cond do
      is_binary(value) and String.starts_with?(value, "preset:") ->
        validate_preset(changeset, ids, "must be a valid #{label} preset")

      get_field(changeset, path_field) ->
        changeset

      true ->
        add_error(changeset, path_field, "is required for uploaded #{label} background")
    end
  end
end
