defmodule Tymeslot.Test.FixtureThemeSpec.Clips do
  @moduledoc """
  A second option group of the fixture theme's own: two uploaded videos, an
  intro and an outro clip, and WebVTT captions for the intro. It stands for
  a theme offering more than one video (a host video beside a background,
  with captions of its own), so the per-field processing
  (one `video_processing_status` entry and one `VideoTranscoder` job per
  field) is proved through a registered theme. It has no choice to make
  (`changes/3` refuses every field) and renders nothing.

  Its settings carry the theme's key as a prefix, as every group's must.
  """
  @behaviour Tymeslot.ThemeCustomizations.OptionGroup

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup

  @asset_fields [
    fixture_intro_clip_path: :video,
    fixture_outro_clip_path: :video,
    fixture_intro_captions_path: :captions
  ]
  @types Map.new(@asset_fields, fn {field, _kind} -> {field, :string} end)

  @impl OptionGroup
  def types, do: @types

  @impl OptionGroup
  def changeset(changeset, attrs, _group), do: cast(changeset, attrs, Map.keys(@types))

  @impl OptionGroup
  def changes(_field, _value, _group), do: :error

  @impl OptionGroup
  def asset_fields(_group), do: @asset_fields

  @impl OptionGroup
  def upload_changes(field, path, _group) when is_map_key(@types, field),
    do: %{Atom.to_string(field) => path}
end
