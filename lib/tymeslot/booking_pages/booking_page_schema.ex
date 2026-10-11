defmodule Tymeslot.BookingPages.BookingPageSchema do
  @moduledoc """
  An extra public start page of a profile, at its own top-level address.

  The profile's own page at `/<username>` is not a row here: its theme and
  texts stay on the profile. A page carries the same page settings the profile
  does (the theme, and the three booking texts with their switch), so
  `Tymeslot.BookingPages.apply_to_profile/2` can lay a page over its owner's
  profile and everything that renders a start page reads the result unchanged.

  The address is trimmed and stored lowercase, follows the username rules and
  stays off the reserved list here; that it is free of every username and
  other page is checked by `Tymeslot.BookingPages`, with the unique index on
  `lower(slug)` as the backstop between pages.
  """
  use Ecto.Schema
  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Themes.Catalog

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          slug: String.t() | nil,
          name: String.t() | nil,
          booking_theme: String.t() | nil,
          booking_text_enabled: boolean(),
          booking_heading: String.t() | nil,
          booking_greeting: String.t() | nil,
          booking_instruction: String.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @name_max_length 60

  schema "booking_pages" do
    field(:slug, :string)
    field(:name, :string)
    field(:booking_theme, :string)
    field(:booking_text_enabled, :boolean, default: false)
    field(:booking_heading, :string)
    field(:booking_greeting, :string)
    field(:booking_instruction, :string)

    belongs_to(:profile, ProfileSchema)

    timestamps(type: :utc_datetime)
  end

  @doc "The longest a page name may be."
  @spec name_max_length() :: pos_integer()
  def name_max_length, do: @name_max_length

  @doc """
  A new page: its owner, starting theme, name and address.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(page, attrs) do
    page
    |> cast(attrs, [:profile_id, :booking_theme])
    |> validate_required([:profile_id, :booking_theme])
    |> validate_theme()
    |> details_changeset(attrs)
    |> foreign_key_constraint(:profile_id)
  end

  @doc """
  The page's name and address, as the dashboard edits them.
  """
  @spec details_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def details_changeset(page_or_changeset, attrs) do
    page_or_changeset
    |> cast(attrs, [:name, :slug])
    |> update_change(:name, &trim/1)
    |> update_change(:slug, &normalize_slug/1)
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: @name_max_length)
    |> validate_slug()
    |> unique_constraint(:slug, name: :booking_pages_slug_index)
  end

  @doc """
  Switches the page to another theme.
  """
  @spec theme_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def theme_changeset(page, theme_id) do
    page
    |> cast(%{booking_theme: theme_id}, [:booking_theme])
    |> validate_required([:booking_theme])
    |> validate_theme()
  end

  # An emptied field casts to nil, which `validate_required/2` reports.
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp normalize_slug(slug) when is_binary(slug), do: slug |> String.trim() |> String.downcase()
  defp normalize_slug(slug), do: slug

  defp validate_slug(changeset) do
    validate_change(changeset, :slug, fn :slug, slug ->
      cond do
        UsernameValidator.validate(slug) != :ok -> [slug: address_format_message()]
        slug in Profiles.reserved_paths() -> [slug: {"is reserved", validation: :reserved}]
        true -> []
      end
    end)
  end

  # Not `UsernameValidator`'s own message: those name a username, and this is
  # a page's address. Built at call time so it follows the caller's locale.
  defp address_format_message do
    dgettext(
      "errors",
      "Use 3 to 30 lowercase letters, numbers, hyphens or underscores, starting with a letter or number"
    )
  end

  defp validate_theme(changeset) do
    validate_change(changeset, :booking_theme, fn :booking_theme, theme_id ->
      if Catalog.valid_id?(theme_id), do: [], else: [booking_theme: "is invalid"]
    end)
  end
end
