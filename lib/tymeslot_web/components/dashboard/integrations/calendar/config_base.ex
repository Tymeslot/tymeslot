defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.ConfigBase do
  @moduledoc """
  Base LiveComponent macro for CalDAV-family provider configuration components.

  It injects shared event handlers and helpers used by provider-specific components
  (e.g., Nextcloud, CalDAV, Radicale) while allowing the render/1 and provider-specific
  instructions to remain customized per component.
  """

  defmacro __using__(opts) do
    opts
    |> extract_using_options()
    |> build_config_base_quote()
  end

  defp extract_using_options(opts) do
    %{
      provider: Keyword.fetch!(opts, :provider),
      default_name: Keyword.get(opts, :default_name, "Calendar")
    }
  end

  defp build_config_base_quote(%{provider: provider, default_name: default_name}) do
    module_setup = module_setup_quote(provider, default_name)
    track_form_change = track_form_change_handler_quote()
    validate_field = validate_field_handler_quote()
    discover_calendars = discover_calendars_handler_quote()
    validation_helpers = validation_helpers_quote()
    discovery_helpers = discovery_helpers_quote()
    name_suggestion = name_suggestion_quote()
    calendar_formatting = calendar_formatting_quote()
    config_defaults = config_defaults_quote()

    quote do
      unquote(module_setup)
      unquote(track_form_change)
      unquote(validate_field)
      unquote(discover_calendars)
      unquote(validation_helpers)
      unquote(discovery_helpers)
      unquote(name_suggestion)
      unquote(calendar_formatting)
      unquote(config_defaults)
    end
  end

  defp module_setup_quote(provider, default_name) do
    quote bind_quoted: [provider: provider, default_name: default_name] do
      use TymeslotWeb, :live_component

      @config_base_provider provider
      @config_base_default_name default_name

      alias Phoenix.Component
      alias Tymeslot.Integrations.Calendar.Discovery
      alias Tymeslot.Security.CalendarInputProcessor
    end
  end

  defp track_form_change_handler_quote do
    quote do
      @impl true
      def handle_event("track_form_change", %{"integration" => params}, socket) do
        {:noreply, Component.assign(socket, :form_values, params)}
      end
    end
  end

  defp validate_field_handler_quote do
    quote do
      @impl true
      def handle_event("validate_field", %{"field" => field} = params, socket) do
        form_values = socket.assigns.form_values || %{}
        integration_params = params["integration"] || form_values
        value = integration_params[field] || ""
        field_atom = field_atom_from(field)

        case CalendarInputProcessor.validate_single_field(field_atom, value,
               metadata: socket.assigns.metadata
             ) do
          {:ok, _} -> handle_valid_field(socket, field_atom)
          {:error, error} -> handle_invalid_field(socket, field_atom, error)
        end
      end
    end
  end

  defp discover_calendars_handler_quote do
    quote do
      @impl true
      def handle_event("discover_calendars", %{"integration" => params}, socket) do
        socket = Component.assign(socket, :saving, true)

        case CalendarInputProcessor.validate_calendar_discovery(params,
               metadata: socket.assigns.metadata,
               provider: @config_base_provider
             ) do
          {:ok, sanitized_params} ->
            handle_discovery_success(socket, sanitized_params)

          {:error, validation_errors} ->
            {:noreply,
             socket
             |> Component.assign(:form_errors, validation_errors)
             |> Component.assign(:saving, false)}
        end
      end
    end
  end

  defp validation_helpers_quote do
    quote do
      defp field_atom_from(field) when is_binary(field) do
        Map.get(
          %{
            "name" => :name,
            "url" => :url,
            "username" => :username,
            "password" => :password,
            "calendar_paths" => :calendar_paths
          },
          field,
          :unknown
        )
      end

      defp handle_valid_field(socket, field_atom) do
        {:noreply, Component.update(socket, :form_errors, &Map.delete(&1 || %{}, field_atom))}
      end

      defp handle_invalid_field(socket, field_atom, error) do
        {:noreply,
         Component.update(
           socket,
           :form_errors,
           &Map.put(&1 || %{}, field_atom, error)
         )}
      end
    end
  end

  defp discovery_helpers_quote do
    quote do
      defp handle_discovery_state(socket, discovery_result) do
        case discovery_result do
          {:ok, %{calendars: calendars, discovery_credentials: credentials}} ->
            socket
            |> Component.assign(:discovered_calendars, calendars)
            |> Component.assign(:show_calendar_selection, true)
            |> Component.assign(:discovery_credentials, credentials)
            |> Component.assign(:saving, false)
            |> Component.assign(:form_errors, %{})

          {:error, reason} ->
            socket
            |> Component.assign(:saving, false)
            |> Component.assign(:form_errors, %{discovery: [reason]})
        end
      end

      defp handle_discovery_success(socket, sanitized_params) do
        discovery_result =
          Discovery.discover_calendars_for_credentials(
            @config_base_provider,
            sanitized_params["url"],
            sanitized_params["username"],
            sanitized_params["password"],
            force_refresh: true
          )

        {:noreply, handle_discovery_state(socket, discovery_result)}
      end
    end
  end

  defp name_suggestion_quote do
    quote do
      defp get_suggested_integration_name(assigns) do
        user_name = extract_user_name(assigns)

        cond do
          user_name != "" ->
            user_name

          has_discovered_calendars?(assigns) ->
            format_calendar_names(Map.get(assigns, :discovered_calendars))

          true ->
            @config_base_default_name
        end
      end

      defp extract_user_name(assigns) do
        assigns[:form_values]
        |> Kernel.||(%{})
        |> Map.get("name", "")
        |> to_string()
        |> String.trim()
      end

      defp has_discovered_calendars?(assigns) do
        is_list(Map.get(assigns, :discovered_calendars)) and
          length(Map.get(assigns, :discovered_calendars)) > 0
      end
    end
  end

  defp calendar_formatting_quote do
    quote do
      defp format_calendar_names(calendars) do
        calendar_names = Enum.map(calendars, & &1.name)

        cond do
          length(calendar_names) == 1 ->
            "#{List.first(calendar_names)}"

          length(calendar_names) <= 3 ->
            Enum.join(calendar_names, ", ")

          true ->
            first_three = calendar_names |> Enum.take(3) |> Enum.join(", ")
            remaining = length(calendar_names) - 3
            "#{first_three} + #{remaining} more"
        end
      end
    end
  end

  defp config_defaults_quote do
    quote do
      def assign_config_defaults(assigns) do
        assigns
        |> assign_new(:show_calendar_selection, fn -> false end)
        |> assign_new(:discovered_calendars, fn -> [] end)
        |> assign_new(:discovery_credentials, fn -> %{} end)
        |> assign_new(:form_values, fn -> %{} end)
        |> assign_new(:form_errors, fn -> %{} end)
        |> assign_new(:saving, fn -> false end)
        |> assign_new(:metadata, fn -> %{} end)
      end
    end
  end
end
