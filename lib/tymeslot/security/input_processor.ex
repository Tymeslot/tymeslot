defmodule Tymeslot.Security.InputProcessor do
  @moduledoc """
  Main entry point for input validation and sanitization.

  Provides a clean API for validating forms with universal sanitization
  followed by field-specific validation with error aggregation.
  """

  alias Tymeslot.Security.{FieldValidators, UniversalSanitizer}

  require Logger

  @type form_params :: %{String.t() => term()}
  @type form_errors :: %{atom() => [String.t()]}

  # Keys whose values must never be passed through the universal sanitiser.
  # These are opaque third-party tokens whose high-entropy byte sequences can
  # incidentally match SQL-injection or path-traversal heuristics, producing
  # false-positive rejections that would corrupt the token before it reaches
  # the external verification API (e.g. Google reCAPTCHA siteverify).
  # The values are preserved in the returned params map unchanged so that
  # downstream callers (reCAPTCHA verification, etc.) still receive them.
  # Passwords are skipped for a different reason: sanitisation MANGLES them.
  # `:strict` mode strips SQL/path heuristics and percent-decodes, so
  # "Pa--ssword1!" sanitises to "Pa" and "0xDEADbeef!A" to "!A". Signup and
  # password reset run params through here, but login compares the RAW string
  # the user typed — so the mangled value gets hashed at signup and can never
  # be matched at login, locking the account permanently. Nothing is lost by
  # skipping: a password is bcrypt-hashed, never rendered or interpolated, so
  # HTML/SQL stripping protects nothing. Length and strength are still enforced
  # by the field-specific `PasswordValidator`.
  @skip_sanitisation_keys [
    "g-recaptcha-response",
    "password",
    "password_confirmation",
    "current_password",
    "new_password",
    "new_password_confirmation"
  ]

  # Validators whose field is an identifier: a value an account is created,
  # looked up or mailed under, or a public booking page is addressed by. Such a
  # field is sanitised in `:plain_text` mode and then accepted or rejected by
  # its validator, never rewritten. `:strict` mode strips `0x<hex>` runs and
  # everything from `--` onwards, so it would turn "crypto0xabc@example.com"
  # into "crypto@example.com", and the username "team--alpha" into "team":
  # each a different, valid identifier that can belong to someone else.
  # Plain-text mode keeps only the changes that cannot alter which identifier
  # it is (null bytes, NFC, trimming).
  @identifier_validators [FieldValidators.EmailValidator, FieldValidators.UsernameValidator]

  @doc """
  Validates a form with universal sanitization and field-specific validation.

  ## Parameters
  - `params` - Form parameters (map with string keys)
  - `field_specs` - List of {field_name, validator_module} tuples
  - `opts` - Options for validation

  ## Options
  - `:metadata` - Metadata for logging (ip, user_id, etc.)
  - `:universal_opts` - Options passed to universal sanitizer

  ## Examples

      InputProcessor.validate_form(params, [
        {"email", :email},
        {"name", :name},
        {"message", :message, [required: false, min_length: 0]}
      ])

      # Also accepts explicit validator modules for backwards compatibility:
      InputProcessor.validate_form(params, [
        {"email", EmailValidator},
        {"name", NameValidator}
      ])

      # Returns:
      {:ok, %{"email" => "user@example.com", "name" => "John", "message" => "Hello"}}
      # or
      {:error, %{email: "Email format is invalid", name: "Name is required"}}
  """
  @spec validate_form(form_params(), list(), keyword()) ::
          {:ok, form_params()} | {:error, form_errors()}
  def validate_form(params, field_specs, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    universal_opts = Keyword.get(opts, :universal_opts, [])

    # Step 1: Universal sanitization for all fields, skipping opaque tokens
    {skipped, sanitisable} = Map.split(params, @skip_sanitisation_keys)
    identifier_keys = identifier_keys(field_specs)

    with {:ok, sanitized_params} <-
           sanitize_all_fields(sanitisable, universal_opts, metadata, identifier_keys) do
      # Step 2: Field-specific validation with error aggregation.
      # Re-merge skipped keys so callers still receive them unchanged.
      all_params = Map.merge(sanitized_params, skipped)
      validate_fields_with_aggregation(all_params, field_specs, metadata)
    end
  end

  @doc """
  Validates a single field with universal sanitization and specific validation.

  Accepts a type atom (`:email`, `:name`, `:password`, etc.) or an explicit
  validator module for backwards compatibility.

  ## Examples

      InputProcessor.validate_field("user@example.com", :email)
      # Returns: {:ok, "user@example.com"}

      InputProcessor.validate_field("<script>alert(1)</script>", :email)
      # Returns: {:error, "Email format is invalid (missing @ symbol)"}
  """
  @spec validate_field(any(), atom(), keyword()) :: {:ok, any()} | {:error, String.t()}
  def validate_field(value, type_or_module, opts \\ []) do
    universal_opts = Keyword.get(opts, :universal_opts, [])
    field = Keyword.get(opts, :field, type_or_module)
    {validator_module, default_opts} = resolve_validator(type_or_module)

    # The caller's request metadata goes into the security log entry the
    # sanitiser writes when it changes the value, as it does for whole forms.
    universal_opts_with_field =
      universal_opts
      |> Keyword.put(:field, field)
      |> Keyword.put_new(:metadata, Keyword.get(opts, :metadata, %{}))
      |> put_identifier_mode(validator_module in @identifier_validators)

    with {:ok, sanitized} <-
           UniversalSanitizer.sanitize_and_validate(value, universal_opts_with_field),
         :ok <- validator_module.validate(sanitized, Keyword.merge(default_opts, opts)) do
      {:ok, sanitized}
    end
  end

  # Private functions

  defp sanitize_all_fields(params, universal_opts, metadata, identifier_keys)
       when is_map(params) do
    base_opts = Keyword.merge(universal_opts, metadata: metadata)

    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      field_key = safe_field_key(key)

      opts_for_field =
        base_opts
        |> Keyword.put(:field, field_key)
        |> put_identifier_mode(MapSet.member?(identifier_keys, to_string(key)))

      case UniversalSanitizer.sanitize_and_validate(value, opts_for_field) do
        {:ok, sanitized_value} ->
          {:cont, {:ok, Map.put(acc, key, sanitized_value)}}

        {:error, reason} ->
          {:halt, {:error, %{field_key => reason}}}
      end
    end)
  end

  # The submitted keys whose spec names an identifier validator. Specs may
  # name a field by atom or string; params arrive with string keys.
  defp identifier_keys(field_specs) do
    for spec <- field_specs,
        elem(resolve_validator(elem(spec, 1)), 0) in @identifier_validators,
        into: MapSet.new(),
        do: to_string(elem(spec, 0))
  end

  defp put_identifier_mode(opts, true), do: Keyword.put(opts, :mode, :plain_text)
  defp put_identifier_mode(opts, false), do: opts

  defp safe_field_key(key) when is_atom(key), do: key

  # Form errors are keyed by atom. Submitted field names are attacker-controlled,
  # so an unknown name must never mint an atom; it keeps its string key instead.
  defp safe_field_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    error in ArgumentError ->
      Logger.debug("Submitted field name has no existing atom; keeping the string key",
        field: key,
        error: Exception.message(error)
      )

      key
  end

  defp safe_field_key(key), do: key

  defp validate_fields_with_aggregation(sanitized_params, field_specs, _metadata) do
    errors =
      Enum.reduce(field_specs, %{}, fn spec, acc ->
        {field_name, type_or_module, field_opts} =
          case spec do
            {f, t, o} -> {f, t, o}
            {f, t} -> {f, t, []}
          end

        {validator_module, default_opts} = resolve_validator(type_or_module)
        field_key = safe_field_key(field_name)

        field_value =
          case field_name do
            name when is_atom(name) ->
              Map.get(sanitized_params, name) || Map.get(sanitized_params, Atom.to_string(name))

            name ->
              Map.get(sanitized_params, name)
          end

        case validator_module.validate(field_value, Keyword.merge(default_opts, field_opts)) do
          :ok ->
            acc

          {:error, reason} ->
            Map.put(acc, field_key, reason)
        end
      end)

    if map_size(errors) == 0 do
      {:ok, sanitized_params}
    else
      {:error, errors}
    end
  end

  # A field type names a validator and the options it starts from; the
  # caller's options are merged over them.
  defp resolve_validator(:email), do: {FieldValidators.EmailValidator, []}
  defp resolve_validator(:password), do: {FieldValidators.PasswordValidator, []}
  defp resolve_validator(:name), do: {FieldValidators.NameValidator, []}
  # A display name is optional, and one letter is a name.
  defp resolve_validator(:full_name),
    do: {FieldValidators.NameValidator, [required: false, min_length: 1]}

  defp resolve_validator(:username), do: {FieldValidators.UsernameValidator, []}
  defp resolve_validator(:message), do: {FieldValidators.MessageValidator, []}
  defp resolve_validator(:text), do: {FieldValidators.TextValidator, []}
  defp resolve_validator(:integration_name), do: {FieldValidators.IntegrationNameValidator, []}
  defp resolve_validator(module) when is_atom(module), do: {module, []}
end
