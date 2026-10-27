defmodule TymeslotWeb.Helpers.FormErrors do
  @moduledoc """
  A refused changeset's errors as form copy, translated through the `errors`
  domain by `Forms.translate_error/1` like every other form error, so a form
  never needs its own interpolation of `%{key}` placeholders.
  """

  alias Ecto.Changeset
  alias Tymeslot.Utils.ChangesetErrors
  alias TymeslotWeb.Components.CoreComponents.Forms

  @doc """
  Every error, keyed by field: `%{field => [message]}`, or for an embedded
  or associated field the nested map (or list of maps) `traverse_errors/2`
  builds.
  """
  @spec to_map(Changeset.t()) :: %{atom() => [String.t()] | map() | [map()]}
  def to_map(%Changeset{} = changeset),
    do: Changeset.traverse_errors(changeset, &Forms.translate_error/1)

  @doc """
  Each field's first error: `%{field => message}`.
  """
  @spec first_per_field(Changeset.t()) :: %{atom() => String.t()}
  def first_per_field(%Changeset{} = changeset),
    do:
      Map.new(to_map(changeset), fn {field, errors} ->
        {field, ChangesetErrors.first_message(errors)}
      end)

  @doc """
  One error for a single line of text: the first field's first message,
  prefixed "Label: " when `labels` (translated field names) names that field,
  for a flash where the field is not in view. `nil` when the changeset has no
  errors. See `Tymeslot.Utils.ChangesetErrors.first/3`.
  """
  @spec first(Changeset.t(), %{atom() => String.t()}) :: String.t() | nil
  def first(%Changeset{} = changeset, labels \\ %{}),
    do: ChangesetErrors.first(changeset, &Forms.translate_error/1, labels)
end
