defmodule TymeslotWeb.Live.Shared.FormValidationHelpers do
  @moduledoc """
  Shared helpers for LiveView form validation and error handling.
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

  def update_field_errors(current_errors, atom_field, {:ok, _}, _normalize_fn) do
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
end
