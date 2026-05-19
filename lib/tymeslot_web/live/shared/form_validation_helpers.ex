defmodule TymeslotWeb.Live.Shared.FormValidationHelpers do
  @moduledoc """
  Shared helpers for LiveView form validation and error handling.

  All forms in the project use the same UX pattern: errors clear as soon
  as the user types into a field and reappear only on blur or save.
  Errors are stored in a `%{atom => message_or_tuple}` map, separate from
  whatever holds the field values, so visibility is driven by user action
  rather than by every live re-validation.

  Two complementary styles share that error map:

    * **Plain-map style** — the form values live in a plain
      `%{"field" => value}` map. Errors are plain strings. Used by the
      public contact and dashboard support forms. See `base_form_params/1`,
      `field_errors/2`, `update_field_errors/4`.

    * **Changeset-backed style** — the form values live in an Ecto
      changeset (e.g. for forms with embedded schemas). Errors are
      `{msg, opts}` tuples copied out of the changeset. See
      `changeset_errors_map/1`, `sync_changeset_field_error/3`,
      `clear_target_error/3`.

  Both styles share the generic primitives `delete_field_error/2` and
  `errors_for_field/2`. Render every input with an explicit `errors=`
  attribute built from `field_errors/2` — never let the form helpers
  derive errors from the underlying changeset directly, or the
  "clear-on-type" behaviour will not work.
  """

  @spec base_form_params([String.t()]) :: map()
  def base_form_params(fields) when is_list(fields) do
    Map.new(fields, &{&1, ""})
  end

  @spec current_form_params(map() | struct() | nil, [String.t()]) :: map()
  def current_form_params(nil, fields), do: base_form_params(fields)

  def current_form_params(%Phoenix.HTML.Form{params: params}, _fields) when is_map(params) do
    params
  end

  def current_form_params(%{} = params, _fields), do: params
  def current_form_params(_other, fields), do: base_form_params(fields)

  @spec atomize_field(String.t(), [String.t()]) :: atom() | nil
  def atomize_field(field, allowed_fields) when is_binary(field) and is_list(allowed_fields) do
    if field in allowed_fields do
      String.to_existing_atom(field)
    else
      nil
    end
  end

  @spec normalize_errors_map(map(), [String.t()]) :: map()
  def normalize_errors_map(errors, allowed_fields) when is_map(errors) do
    allowed_atoms = MapSet.new(Enum.map(allowed_fields, &String.to_existing_atom/1))
    allowed_lookup = Map.new(allowed_fields, &{&1, String.to_existing_atom(&1)})

    errors
    |> Enum.map(fn {field, msg} ->
      atom_field =
        cond do
          is_atom(field) -> field
          is_binary(field) -> Map.get(allowed_lookup, field)
          true -> nil
        end

      {atom_field, msg}
    end)
    |> Enum.reject(fn {field, _msg} ->
      is_nil(field) or not MapSet.member?(allowed_atoms, field)
    end)
    |> Enum.into(%{})
  end

  @spec errors_for_field(map(), atom() | nil) :: map()
  def errors_for_field(_errors, nil), do: %{}
  def errors_for_field(errors, field) when is_atom(field), do: Map.take(errors, [field])

  @spec delete_field_error(map(), atom() | nil) :: map()
  def delete_field_error(errors, nil), do: errors

  def delete_field_error(errors, field) when is_atom(field) do
    errors
    |> Map.delete(field)
    |> Map.delete(Atom.to_string(field))
  end

  @doc """
  Updates form errors for a specific field based on validation results.
  """
  @spec update_field_errors(map(), atom() | nil, {:ok, any()} | {:error, map()}, (map() -> map())) ::
          map()
  def update_field_errors(current_errors, nil, _validation_result, _normalize_fn),
    do: current_errors

  def update_field_errors(current_errors, atom_field, {:ok, _result}, _normalize_fn) do
    delete_field_error(current_errors, atom_field)
  end

  def update_field_errors(current_errors, atom_field, {:error, errors}, normalize_fn) do
    normalized_errors = normalize_fn.(errors)
    field_errors = errors_for_field(normalized_errors, atom_field)

    current_errors
    |> delete_field_error(atom_field)
    |> Map.merge(field_errors)
  end

  @spec field_errors(map(), atom()) :: [String.t()]
  def field_errors(errors, field) when is_atom(field) do
    case Map.get(errors, field) do
      nil -> []
      error when is_binary(error) -> [error]
      error -> List.wrap(error)
    end
  end

  # ========== Changeset-backed form helpers ==========
  # The functions below pair with an Ecto changeset that owns the canonical
  # form state. Display errors live in a separate `%{atom => {msg, opts}}`
  # map so visibility is driven by user action (typing clears, blur
  # re-validates, save populates) rather than by every live re-validation.

  @doc """
  Builds a `%{atom => {msg, opts}}` map from every error on `changeset`.

  Use in the save handler when validation fails to populate the display
  errors map with all problems at once.
  """
  @spec changeset_errors_map(Ecto.Changeset.t()) :: map()
  def changeset_errors_map(%Ecto.Changeset{errors: errors}), do: Map.new(errors)

  @doc """
  Updates the display errors for one field by consulting `changeset`.

  Use in a `phx-blur` handler: if the live changeset reports an error for
  `field`, the entry is set in `field_errors`; otherwise it's cleared.
  """
  @spec sync_changeset_field_error(map(), Ecto.Changeset.t(), atom()) :: map()
  def sync_changeset_field_error(field_errors, %Ecto.Changeset{} = changeset, field)
      when is_atom(field) do
    case Enum.find(changeset.errors, fn {f, _error} -> f == field end) do
      nil -> Map.delete(field_errors, field)
      {_field, error_tuple} -> Map.put(field_errors, field, error_tuple)
    end
  end

  @doc """
  Clears the display error for whichever field the user just touched.

  Use in a `phx-change` handler so the error for a field disappears the
  moment the user starts typing. `target` is the `_target` list Phoenix
  sends, e.g. `["definition", "label"]` or
  `["definition", "options", "0", "label"]`. `allowed_fields` lists every
  form-field name that can carry a display error.
  """
  @spec clear_target_error(map(), [String.t()] | nil, [String.t()]) :: map()
  def clear_target_error(field_errors, [_form, field_name | _rest], allowed_fields)
      when is_binary(field_name) and is_list(allowed_fields) do
    delete_field_error(field_errors, atomize_field(field_name, allowed_fields))
  end

  def clear_target_error(field_errors, _target, _allowed_fields), do: field_errors
end
