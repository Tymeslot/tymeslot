defmodule TymeslotWeb.Dashboard.VideoSettings.FormInput do
  @moduledoc """
  Marshalling and field-level validation of the video integration form for
  `TymeslotWeb.Dashboard.VideoSettingsComponent`.

  Every value handled here arrives from the browser, so this is the single
  place where an untrusted string becomes an internal term: a submitted
  parameter key only becomes an atom when that atom already exists, an
  integration id is parsed rather than trusted, and an unrecognised field name
  degrades to `:unknown` instead of raising. Holding those rules apart from the
  component keeps the component to socket state and event routing, and gives
  the conversions one place to be tested and extended as providers gain fields.
  """

  alias Tymeslot.Integrations.Video.InputValidation, as: VideoInputValidation
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  require Logger

  @field_atoms %{
    "name" => :name,
    "base_url" => :base_url,
    "api_key" => :api_key,
    "custom_meeting_url" => :custom_meeting_url
  }

  @doc """
  Re-validates a single form field and returns the updated error map.

  A blank value clears that field's error instead of reporting one: whether the
  field is required depends on the provider and is settled on submit, so
  blanking a field mid-edit must not shout at the user.
  """
  @spec validate_field(map(), String.t(), term(), map()) :: map()
  def validate_field(form_errors, field, value, metadata) do
    field_atom = field_atom(field)

    if String.trim(to_string(value)) == "" do
      FormValidationHelpers.delete_field_error(form_errors, field_atom)
    else
      case VideoInputValidation.validate_single_field(field_atom, value, metadata: metadata) do
        {:ok, _sanitized_value} ->
          FormValidationHelpers.delete_field_error(form_errors, field_atom)

        {:error, error} ->
          Map.put(form_errors, field_atom, error)
      end
    end
  end

  @doc """
  Maps a submitted field name onto the atom the validators dispatch on.

  Anything outside the known set becomes `:unknown`, which every validator
  clause accepts and passes through.
  """
  @spec field_atom(String.t()) :: atom()
  def field_atom(field), do: Map.get(@field_atoms, field, :unknown)

  @doc """
  Converts a params map's string keys to atoms for the context call.

  A key with no existing atom keeps its string form and is rejected downstream,
  so user-submitted keys can never mint atoms.
  """
  @spec to_atom_keys(map()) :: map()
  def to_atom_keys(%{} = params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {existing_atom(key), value}
    end)
  end

  @doc """
  Parses an integration id coming from a client event, returning `nil` when it
  is not a plain integer.
  """
  @spec integration_id(term()) :: integer() | nil
  def integration_id(id) when is_integer(id), do: id

  def integration_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _other -> nil
    end
  end

  def integration_id(_other), do: nil

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    error in ArgumentError ->
      Logger.debug("Video integration param has no existing atom; keeping the string key",
        param: key,
        error: Exception.message(error)
      )

      key
  end
end
