defmodule Tymeslot.CustomFields.FieldOption do
  @moduledoc """
  Embedded schema for one option of a `single_select` or `multi_select`
  custom field definition.

  An option has a stable server-generated `key` (the value stored on a
  booking when the option is selected) and a host-authored `label` that
  the booker sees.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :key, :string
    field :label, :string
  end

  @doc """
  Builds a changeset. If `key` is missing, derives one from the label
  (snake_cased ASCII slug with a random suffix to avoid collisions).
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(option, attrs) do
    option
    |> cast(attrs, [:key, :label])
    |> validate_required([:label])
    |> validate_length(:label, max: 80)
    |> then(fn cs -> if cs.valid?, do: maybe_derive_key(cs), else: cs end)
  end

  defp maybe_derive_key(cs) do
    case get_field(cs, :key) do
      key when is_binary(key) and key != "" -> cs
      _other -> put_change(cs, :key, derive_key(get_field(cs, :label)))
    end
  end

  defp derive_key(nil), do: random_key()

  defp derive_key(label) do
    slug =
      label
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 24)

    suffix =
      :crypto.strong_rand_bytes(3)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 4)

    if slug == "", do: random_key(), else: slug <> "_" <> suffix
  end

  defp random_key do
    encoded = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    "opt_" <> encoded
  end
end
