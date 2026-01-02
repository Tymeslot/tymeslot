defmodule Tymeslot.Integrations.Calendar.Creation do
  @moduledoc """
  Business logic for creating calendar integrations with validation and
  enforcing primary-integration invariants.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Security.CalendarInputProcessor

  @type user_id :: pos_integer()

  @doc """
  Validates incoming params (security-aware), creates the integration via Calendar,
  and ensures the first integration becomes primary.

  Returns:
    {:ok, %CalendarIntegrationSchema{}}
    {:error, {:form_errors, map()}}
    {:error, {:changeset, %Ecto.Changeset{}}}
    {:error, term()}
  """
  @spec create_with_validation(user_id(), map(), keyword()) ::
          {:ok, map()}
          | {:error, {:form_errors, map()} | {:changeset, Ecto.Changeset.t()} | term()}
  def create_with_validation(user_id, params, opts \\ [])
      when is_integer(user_id) and is_map(params) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized} <-
           CalendarInputProcessor.validate_calendar_integration_form(params, metadata: metadata),
         validated <- Map.merge(params, sanitized),
         count_before <- length(CalendarManagement.list_calendar_integrations(user_id)),
         {:ok, integration} <- Calendar.create_integration(validated, user_id) do
      ensure_primary_on_first(user_id, integration.id, count_before)
      {:ok, integration}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:error, {:changeset, cs}}

      {:error, validation_errors} when is_map(validation_errors) ->
        {:error, {:form_errors, validation_errors}}
    end
  end

  @doc """
  If this was the user's first integration, set it as primary.
  """
  @spec ensure_primary_on_first(user_id(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def ensure_primary_on_first(user_id, new_integration_id, count_before) do
    case count_before do
      0 -> CalendarPrimary.set_primary_calendar_integration(user_id, new_integration_id)
      _ -> :ok
    end
  end

  # ---------------------------
  # Param shaping and pre-validation (moved from facade)
  # ---------------------------

  @doc """
  Prepare attributes for creating an integration from UI params.
  """
  @spec prepare_attrs(map(), user_id()) :: {:ok, map()}
  def prepare_attrs(params, user_id) when is_map(params) and is_integer(user_id) do
    %{
      "name" => name,
      "provider" => provider,
      "url" => url,
      "username" => username,
      "password" => password,
      "calendar_paths" => calendar_paths
    } = params

    {base_url, calendar_paths_list} = parse_calendar_configuration(provider, url, calendar_paths)

    attrs = %{
      user_id: user_id,
      name: name,
      provider: provider,
      base_url: base_url,
      username: username,
      password: password,
      calendar_paths: calendar_paths_list,
      is_active: true
    }

    attrs
    |> maybe_add_calendar_list(params["calendar_list"])
    |> ensure_calendar_list(calendar_paths_list)
    |> then(&{:ok, &1})
  end

  defp maybe_add_calendar_list(attrs, nil), do: attrs

  defp maybe_add_calendar_list(attrs, calendar_list) do
    formatted_calendar_list = Enum.map(calendar_list, &format_calendar_item/1)
    Map.put(attrs, :calendar_list, formatted_calendar_list)
  end

  defp format_calendar_item(calendar) do
    id = derive_id(calendar)
    path = derive_path(calendar, id)
    name = derive_name(calendar, path)
    type = derive_type(calendar)

    %{
      "id" => id || path,
      "path" => path,
      "name" => name,
      "type" => type,
      "selected" => true
    }
  end

  defp derive_id(calendar) do
    Map.get(calendar, :id) || Map.get(calendar, "id") || Map.get(calendar, :path) ||
      Map.get(calendar, "path")
  end

  defp derive_path(calendar, id) do
    Map.get(calendar, :path) || Map.get(calendar, "path") || id
  end

  defp derive_name(calendar, path) do
    Map.get(calendar, :name) || Map.get(calendar, "name") || path || "Calendar"
  end

  defp derive_type(calendar) do
    Map.get(calendar, :type) || Map.get(calendar, "type") || "calendar"
  end

  defp ensure_calendar_list(attrs, calendar_paths_list) do
    case {Map.get(attrs, :calendar_list), calendar_paths_list} do
      {list, _} when is_list(list) and length(list) > 0 ->
        attrs

      {_, paths} when is_list(paths) and length(paths) > 0 ->
        Map.put(attrs, :calendar_list, build_calendar_list_from_paths(paths))

      _ ->
        attrs
    end
  end

  defp build_calendar_list_from_paths(paths) do
    Enum.map(paths, fn path ->
      name = extract_calendar_name_from_path(path)

      %{
        "id" => path,
        "path" => path,
        "name" => name,
        "type" => "calendar",
        "selected" => true
      }
    end)
  end

  defp extract_calendar_name_from_path(path) do
    path
    |> String.trim_trailing("/")
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> List.last() || path
  end

  @doc false
  defp parse_calendar_configuration(_provider, url, calendar_paths) do
    cond do
      is_binary(calendar_paths) and String.trim(calendar_paths) == "" ->
        {url, []}

      is_binary(calendar_paths) and String.contains?(calendar_paths, "://") ->
        PathUtils.extract_calendar_paths(calendar_paths)

      is_binary(calendar_paths) and String.contains?(calendar_paths, ",") ->
        parse_comma_separated_paths(url, calendar_paths)

      true ->
        parse_newline_separated_paths(url, calendar_paths)
    end
  end

  defp parse_comma_separated_paths(url, calendar_paths) do
    paths =
      calendar_paths
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {url, paths}
  end

  defp parse_newline_separated_paths(url, calendar_paths) do
    paths =
      calendar_paths
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {url, paths}
  end

  @doc """
  Pre-validate CalDAV/Nextcloud/Radicale configuration before saving.
  OAuth providers do not need pre-validation.

  - Uses ProviderRegistry for provider validation/lookup
  - Uses Shared.ErrorHandler to sanitize provider-specific error messages
  """
  @spec prevalidate_config(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def prevalidate_config(%{provider: provider} = attrs)
      when provider in ["caldav", "nextcloud", "radicale"] do
    config = %{
      base_url: attrs[:base_url],
      username: attrs[:username],
      password: attrs[:password],
      calendar_paths: attrs[:calendar_paths] || []
    }

    with {:ok, provider_atom} <- ProviderRegistry.validate_provider(provider),
         {:ok, provider_module} <- ProviderRegistry.get_provider(provider_atom) do
      case provider_module.validate_config(config) do
        :ok ->
          {:ok, attrs}

        {:error, reason} ->
          message = ErrorHandler.sanitize_error_message(reason, provider_atom)
          {:error, ErrorHandler.create_validation_error(message)}
      end
    else
      # If provider validation/lookup fails, skip pre-validation and allow creation to proceed
      {:error, _} -> {:ok, attrs}
    end
  end

  def prevalidate_config(attrs) when is_map(attrs) do
    # OAuth providers and any non-Caldav-like providers don't need pre-validation
    {:ok, attrs}
  end
end
