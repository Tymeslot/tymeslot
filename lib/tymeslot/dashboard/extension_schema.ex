defmodule Tymeslot.Dashboard.ExtensionSchema do
  @moduledoc """
  Schema validation for dashboard extensions.

  Dashboard extensions allow external applications to register
  new navigation items and components in the Core dashboard without Core
  having any knowledge of the extension source.

  ## Extension Structure

  Extensions are configured as a list of maps with the following structure:

      %{
        id: :subscription,           # Unique identifier for this extension
        label: "Subscription",        # Display text in sidebar
        icon: :credit_card,          # Icon name (must exist in IconComponents)
        path: "/dashboard/subscription", # Route path for this section
        action: :subscription        # LiveView action atom
      }

  ## Usage

  Extensions should be registered during application startup via
  `Application.put_env/3`:

      # In your application.ex
      Application.put_env(:tymeslot, :dashboard_sidebar_extensions, [
        %{
          id: :my_feature,
          label: "My Feature",
          icon: :puzzle,
          path: "/dashboard/my-feature",
          action: :my_feature
        }
      ])

  Corresponding components should also be registered:

      Application.put_env(:tymeslot, :dashboard_action_components, %{
        my_feature: MyApp.Dashboard.MyFeatureComponent
      })

  ## Validation

  To validate extensions at startup and catch configuration errors early:

      extensions = Application.get_env(:tymeslot, :dashboard_sidebar_extensions, [])

      case ExtensionSchema.validate_all(extensions) do
        :ok -> :ok
        {:error, errors} ->
          Logger.error("Invalid dashboard extensions: \#{inspect(errors)}")
          raise "Dashboard extension validation failed"
      end
  """

  require Logger

  alias TymeslotWeb.Components.Icons.IconComponents

  @type extension :: %{
          id: atom(),
          label: String.t(),
          icon: atom(),
          path: String.t(),
          action: atom()
        }

  @type validation_error :: {integer() | atom(), String.t()}

  @required_fields [:id, :label, :icon, :path, :action]

  @doc """
  Validates a list of dashboard extensions.

  Returns `:ok` if all extensions are valid, or `{:error, errors}` with
  a list of validation errors.

  ## Examples

      iex> ExtensionSchema.validate_all([
      ...>   %{id: :test, label: "Test", icon: :home, path: "/test", action: :test}
      ...> ])
      :ok

      iex> ExtensionSchema.validate_all([
      ...>   %{id: :test, label: "Test", icon: :invalid, path: "/test", action: :test}
      ...> ])
      {:error, [{0, "Invalid icon :invalid. Must be one of: ..."}]}
  """
  @spec validate_all([map()]) :: :ok | {:error, [validation_error()]}
  def validate_all(extensions) when is_list(extensions) do
    errors =
      extensions
      |> Enum.with_index()
      |> Enum.flat_map(fn {ext, index} ->
        case validate(ext) do
          :ok -> []
          {:error, field_errors} -> Enum.map(field_errors, &{index, &1})
        end
      end)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  @doc """
  Validates a single dashboard extension.

  Returns `:ok` if the extension is valid, or `{:error, errors}` with
  a list of validation error messages.

  ## Examples

      iex> ExtensionSchema.validate(%{
      ...>   id: :subscription,
      ...>   label: "Subscription",
      ...>   icon: :credit_card,
      ...>   path: "/dashboard/subscription",
      ...>   action: :subscription
      ...> })
      :ok

      iex> ExtensionSchema.validate(%{id: :test})
      {:error, [
        "Missing required field: label",
        "Missing required field: icon",
        "Missing required field: path",
        "Missing required field: action"
      ]}
  """
  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(extension) when is_map(extension) do
    errors =
      []
      |> validate_required_fields(extension)
      |> validate_field_types(extension)
      |> validate_icon(extension)
      |> validate_path(extension)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  @doc """
  Returns the list of available icon names from the IconComponents system.
  """
  @spec available_icons() :: [atom()]
  def available_icons, do: IconComponents.supported_icons()

  # Private validation functions

  defp validate_required_fields(errors, extension) do
    missing =
      @required_fields
      |> Enum.reject(&Map.has_key?(extension, &1))
      |> Enum.map(&"Missing required field: #{&1}")

    errors ++ missing
  end

  defp validate_field_types(errors, extension) do
    type_errors =
      Enum.reject(
        [
          validate_type(extension, :id, :atom),
          validate_type(extension, :label, :string),
          validate_type(extension, :icon, :atom),
          validate_type(extension, :path, :string),
          validate_type(extension, :action, :atom)
        ],
        &is_nil/1
      )

    errors ++ type_errors
  end

  defp validate_type(extension, field, expected_type) do
    case Map.get(extension, field) do
      nil ->
        "Field :#{field} is required and cannot be nil"

      value ->
        valid =
          case expected_type do
            :atom -> is_atom(value)
            :string -> is_binary(value)
          end

        if valid do
          nil
        else
          "Field :#{field} must be a #{expected_type}, got: #{inspect(value)}"
        end
    end
  end

  defp validate_icon(errors, extension) do
    available = IconComponents.supported_icons()
    icon = Map.get(extension, :icon)

    cond do
      is_nil(icon) ->
        errors

      icon in available ->
        errors

      is_atom(icon) ->
        errors ++
          [
            "Invalid icon :#{icon}. Must be one of: #{Enum.join(available, ", ")}"
          ]

      true ->
        errors
    end
  end

  defp validate_path(errors, extension) do
    case Map.get(extension, :path) do
      nil ->
        errors

      path when is_binary(path) ->
        if String.starts_with?(path, "/") do
          errors
        else
          errors ++ ["Path must start with '/': #{path}"]
        end

      _invalid_path ->
        errors
    end
  end

  @doc """
  Validates and logs errors for dashboard extensions at application startup.

  This is a convenience function that validates extensions and logs any errors.
  If validation fails, it raises an error to prevent the application from
  starting with invalid configuration.

  ## Examples

      # In your application.ex start/2 function:
      ExtensionSchema.validate_and_log!(:dashboard_sidebar_extensions)
  """
  @spec validate_and_log!(atom()) :: :ok
  def validate_and_log!(config_key) do
    extensions = Application.get_env(:tymeslot, config_key, [])

    case validate_all(extensions) do
      :ok ->
        :ok

      {:error, errors} ->
        Logger.error("""
        Invalid dashboard extensions in config key :#{config_key}

        Errors:
        #{format_errors(errors)}
        """)

        raise "Dashboard extension validation failed. Check logs for details."
    end
  end

  @doc """
  Validates that all registered sidebar extensions have corresponding components.
  """
  @spec validate_components([map()], map()) :: :ok | {:error, [String.t()]}
  def validate_components(extensions, components) do
    sidebar_actions = Enum.map(extensions, & &1.action)
    registered_actions = Map.keys(components)

    missing =
      sidebar_actions
      |> Enum.reject(&(&1 in registered_actions))
      |> Enum.map(&"Missing component registration for action: :#{&1}")

    invalid =
      components
      |> Enum.reject(fn {_action_key, module} ->
        is_atom(module) && Code.ensure_loaded?(module)
      end)
      |> Enum.map(fn {action, module} ->
        "Invalid component module for action :#{action}: #{inspect(module)} (module not found)"
      end)

    case missing ++ invalid do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc """
  Formats validation errors into a human-readable string.
  """
  @spec format_errors([validation_error() | String.t()]) :: String.t()
  def format_errors(errors) do
    Enum.map_join(errors, "\n", fn
      {index, error} -> "  Extension ##{index}: #{error}"
      error -> "  #{error}"
    end)
  end
end
