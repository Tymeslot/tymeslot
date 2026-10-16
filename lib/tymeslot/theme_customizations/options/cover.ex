defmodule Tymeslot.ThemeCustomizations.Options.Cover do
  @moduledoc """
  The cover option: the wide image across the top of a booking page, one of
  the group's preset covers or an image the organiser uploaded. Stored as
  `cover_value` (a preset id, or `"custom"` for the upload) and `cover_path`
  (the uploaded file).

  An `OptionGroup`: a spec lists it as `%{key: :cover, module:
  Options.Cover, presets: [ids], default: id}`, naming the covers its theme
  offers (from `Presets.Covers`, in picker order) and the one shown while
  none is stored. `changeset/3` refuses a preset the group does not list and
  a custom cover without its file. Choosing a preset drops the upload, so the
  save deletes its file; an upload into `cover_path` becomes the custom
  cover. `media/2` hands the resolved cover to `Tokens.media` as `:cover`:
  `%{src: url, preset: id}` for a preset (resolved from the whole catalogue,
  as a background's is), `%{src: url, preset: nil}` for the upload (its URL
  sanitised as an uploaded background's is), or `nil` when the stored value
  resolves to nothing.
  """
  @behaviour Tymeslot.ThemeCustomizations.OptionGroup

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Validation

  @types %{cover_value: :string, cover_path: :string}

  @typedoc "A cover group: the covers the theme offers, in picker order, and the default."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:presets) => [String.t()],
          required(:default) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "A resolved, render-ready cover; `preset` is `nil` for an uploaded one."
  @type cover :: %{src: String.t(), preset: String.t() | nil}

  @impl OptionGroup
  def types, do: @types

  @impl OptionGroup
  def changeset(changeset, attrs, group) do
    changeset
    |> cast(attrs, Map.keys(@types))
    |> validate_value(preset_ids(group))
  end

  @impl OptionGroup
  def changes("cover_value", id, group) do
    if id in preset_ids(group),
      do: {:ok, %{"cover_value" => id, "cover_path" => nil}},
      else: :error
  end

  def changes(_field, _value, _group), do: :error

  @impl OptionGroup
  def asset_fields(_group), do: [cover_path: :image]

  @impl OptionGroup
  def upload_changes(:cover_path, path, _group),
    do: %{"cover_value" => "custom", "cover_path" => path}

  @impl OptionGroup
  @spec media(Spec.settings(), group()) :: %{cover: cover() | nil}
  def media(settings, group),
    do: %{cover: resolve(settings["cover_value"] || group[:default], settings)}

  @doc "The group's covers as `{id, preset}`, in the group's order."
  @spec presets(group()) :: [{String.t(), Presets.preset()}]
  def presets(group), do: Presets.take(:cover, preset_ids(group))

  defp resolve("custom", %{"cover_path" => path}) when is_binary(path) and path != "",
    do: %{src: "/uploads/" <> Validation.sanitize_path(path), preset: nil}

  defp resolve(id, _settings) when is_binary(id) do
    case Presets.find_preset_by_id(:cover, id) do
      %{src: src} -> %{src: src, preset: id}
      nil -> nil
    end
  end

  defp resolve(_value, _settings), do: nil

  defp preset_ids(group), do: Map.get(group, :presets, [])

  defp validate_value(changeset, ids) do
    case get_field(changeset, :cover_value) do
      nil -> changeset
      "custom" -> validate_upload(changeset)
      id when is_binary(id) -> validate_preset(changeset, id, ids)
    end
  end

  defp validate_upload(changeset) do
    if get_field(changeset, :cover_path),
      do: changeset,
      else: add_error(changeset, :cover_path, "is required for an uploaded cover")
  end

  defp validate_preset(changeset, id, ids) do
    if id in ids,
      do: changeset,
      else: add_error(changeset, :cover_value, "must be a valid cover preset")
  end
end
