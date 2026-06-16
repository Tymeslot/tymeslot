defmodule Tymeslot.MeetingTypes.Slugs do
  @moduledoc """
  Slug resolution and custom-slug management for meeting types.

  A meeting type's URL is identified by its *effective slug*: the custom slug
  when one has been set, otherwise a slug derived from the name. Custom slugs
  power private/direct booking links — a readable or randomised secret address
  that reaches a single meeting type without exposing the rest of a public page.
  """

  alias Tymeslot.MeetingTypes.MeetingTypeQueries

  @doc """
  Finds a meeting type by its effective slug.

  Resolves against active types only — including private ones, which carry no
  public listing but are still bookable through their direct link. An inactive
  type is therefore unreachable, which is what pauses a shared link when the
  organiser turns the type off.
  """
  @spec find_by_slug(integer(), String.t()) :: Ecto.Schema.t() | nil
  def find_by_slug(user_id, slug) do
    active = MeetingTypeQueries.list_active_meeting_types(user_id)

    # Prefer a type whose custom `slug` field is an exact match over one that
    # only matches via its name-derived slug. This prevents a public type from
    # shadowing a private type (or any other type with a custom slug) when both
    # would yield the same effective slug.
    Enum.find(active, fn mt -> mt.slug == slug end) ||
      Enum.find(active, fn mt -> effective_slug(mt) == slug end)
  end

  @doc """
  The slug that identifies a meeting type in its URL: the custom slug when one
  has been set, otherwise the slug derived from the name.
  """
  @spec effective_slug(Ecto.Schema.t()) :: String.t()
  def effective_slug(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  def effective_slug(meeting_type), do: to_slug(meeting_type)

  @doc """
  Derives a slug from a meeting type's name.
  """
  @spec to_slug(Ecto.Schema.t()) :: String.t()
  def to_slug(meeting_type) do
    meeting_type.name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  The effective slug, used in URLs. (Historically called the "duration string".)
  """
  @spec to_duration_string(Ecto.Schema.t()) :: String.t()
  def to_duration_string(meeting_type) do
    effective_slug(meeting_type)
  end

  @doc """
  Generates a random, unguessable booking slug that does not collide with any of
  the user's existing meeting-type slugs. Used by the "randomise link" action to
  turn a readable link into a secret one (and to rotate a leaked link).
  """
  @spec generate_random_slug(integer()) :: String.t()
  def generate_random_slug(user_id) do
    taken = taken_slugs(user_id, nil)

    Enum.find(Stream.repeatedly(&random_slug_token/0), fn slug ->
      not MapSet.member?(taken, slug)
    end)
  end

  @doc """
  Normalises a user-supplied slug the same way the schema does: blank becomes
  `nil` (derive from name), otherwise trimmed and downcased.
  """
  @spec normalize_slug(String.t() | nil) :: String.t() | nil
  def normalize_slug(nil), do: nil

  def normalize_slug(slug) when is_binary(slug) do
    case slug |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  @doc """
  Sets (or clears) a meeting type's custom booking slug.

  Pass `nil` or a blank string to revert to the name-derived slug. Changing the
  slug invalidates any link previously shared for this type, so callers must
  confirm intent before calling this. Returns `{:error, :slug_taken}` when the
  slug collides with another of the user's meeting types.
  """
  @spec update_slug(Ecto.Schema.t(), String.t() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, :slug_taken | Ecto.Changeset.t()}
  def update_slug(meeting_type, slug) do
    attrs = %{slug: normalize_slug(slug)}

    with :ok <- gate_slug_available(meeting_type.user_id, attrs, meeting_type.id) do
      MeetingTypeQueries.update_slug(meeting_type, attrs)
    end
  end

  defp random_slug_token do
    8 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end

  # Effective slugs already taken by the user's other meeting types (optionally
  # excluding one, so a type doesn't conflict with itself on update).
  defp taken_slugs(user_id, exclude_id) do
    user_id
    |> MeetingTypeQueries.list_all_meeting_types()
    |> Enum.reject(fn mt -> exclude_id && mt.id == exclude_id end)
    |> Enum.map(&effective_slug/1)
    |> MapSet.new()
  end

  # A custom slug must not collide with another of the user's meeting types,
  # whether that sibling carries a custom slug or a name-derived one (the latter
  # is invisible to the DB unique index, so it is checked here).
  defp gate_slug_available(_user_id, %{slug: nil}, _exclude_id), do: :ok

  defp gate_slug_available(user_id, %{slug: slug}, exclude_id) when is_binary(slug) do
    if MapSet.member?(taken_slugs(user_id, exclude_id), slug),
      do: {:error, :slug_taken},
      else: :ok
  end
end
