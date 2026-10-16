defmodule Tymeslot.ThemeCustomizations.Options.Logo do
  @moduledoc """
  The logo option: one image the organiser uploads, for a theme that shows a
  logo on its booking page. Stored as `logo_path`, the uploaded file.

  An `OptionGroup` with no configuration: a spec lists it as `%{key: :logo,
  module: Options.Logo}`. The file arrives only through an upload into its
  one asset field (`upload_changes/3`), which replaces the previous logo, so
  the save deletes the old file; the one choice it takes is removing the
  logo (`changes("logo_path", "", group)`), which deletes the file too.
  `media/2` hands it to `Tokens.media` as `:logo`: `%{src: url}`, the URL
  sanitised as an uploaded background's is, or `nil` without a logo.
  """
  @behaviour Tymeslot.ThemeCustomizations.OptionGroup

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Validation

  @typedoc "A resolved, render-ready logo."
  @type logo :: %{src: String.t()}

  @impl OptionGroup
  def types, do: %{logo_path: :string}

  @impl OptionGroup
  def changeset(changeset, attrs, _group), do: cast(changeset, attrs, [:logo_path])

  @impl OptionGroup
  def changes("logo_path", "", _group), do: {:ok, %{"logo_path" => nil}}
  def changes(_field, _value, _group), do: :error

  @impl OptionGroup
  def asset_fields(_group), do: [logo_path: :image]

  @impl OptionGroup
  def upload_changes(:logo_path, path, _group), do: %{"logo_path" => path}

  @impl OptionGroup
  @spec media(Spec.settings(), OptionGroup.group()) :: %{logo: logo() | nil}
  def media(%{"logo_path" => path}, _group) when is_binary(path) and path != "",
    do: %{logo: %{src: "/uploads/" <> Validation.sanitize_path(path)}}

  def media(_settings, _group), do: %{logo: nil}
end
