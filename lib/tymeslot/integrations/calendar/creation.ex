defmodule Tymeslot.Integrations.Calendar.Creation do
  @moduledoc """
  Business logic for creating calendar integrations with validation and
  enforcing primary-integration invariants.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.InputValidation, as: CalendarInputValidation
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Utils.SanitizeMerge

  @type user_id :: pos_integer()

  @caldav_provider_strings ProviderConfig.caldav_based_provider_strings()

  @doc """
  Validates incoming params (security-aware), creates the integration via Calendar,
  and ensures the first integration becomes primary.

  Returns:
    {:ok, %CalendarIntegrationSchema{}}
    {:error, {:form_errors, map()}}
    {:error, {:changeset, %Ecto.Changeset{}}}
    {:error, {:rate_limited, String.t()}}
    {:error, :unattributable}
    {:error, term()}
  """
  @spec create_with_validation(user_id(), %{String.t() => term()}, keyword()) ::
          {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()}
          | {:error,
             {:form_errors, %{String.t() => term()}}
             | {:changeset, Ecto.Changeset.t()}
             | {:rate_limited, String.t()}
             | :unattributable
             | term()}
  def create_with_validation(user_id, params, opts \\ [])
      when is_integer(user_id) and is_map(params) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized} <-
           CalendarInputValidation.validate_calendar_integration_form(params, metadata: metadata),
         validated <- SanitizeMerge.merge(params, sanitized),
         :ok <- check_no_duplicate_calendar(user_id, validated),
         count_before <- length(CalendarManagement.list_calendar_integrations(user_id)),
         {:ok, integration} <- Calendar.create_integration(validated, user_id) do
      ensure_primary_on_first(user_id, integration.id, count_before)
      {:ok, integration}
    else
      {:error, :duplicate_integration} ->
        {:error, :duplicate_integration}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, {:changeset, cs}}

      # `Creation.prevalidate_config/1`'s refusal, passed straight up still
      # tagged — see its doc.
      {:error, {:rate_limited, _message} = refusal} ->
        {:error, refusal}

      {:error, :unattributable} ->
        {:error, :unattributable}

      {:error, validation_errors} when is_map(validation_errors) ->
        {:error, {:form_errors, validation_errors}}
    end
  end

  # Keys are strings throughout: the params come from the form, and
  # `InputValidation.validate_calendar_integration_form/2` returns a
  # string-keyed map that `SanitizeMerge.merge/2` folds back into them.
  defp check_no_duplicate_calendar(user_id, params) do
    provider = params["provider"]
    url = params["url"]
    username = params["username"]
    calendar_paths = params["calendar_paths"]

    if is_binary(url) and url != "" and is_binary(username) and username != "" and
         is_binary(provider) do
      # Derive account_id using the same normalization as prepare_attrs
      {base_url, _paths} = parse_calendar_configuration(provider, url, calendar_paths)
      account_id = "#{base_url}||#{username}"

      # Check both active and inactive integrations to prevent duplicate rows
      case CalendarIntegrationQueries.get_any_by_account_for_user(user_id, provider, account_id) do
        {:ok, _existing} -> {:error, :duplicate_integration}
        {:error, :not_found} -> :ok
      end
    else
      :ok
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
      _count -> :ok
    end
  end

  # ---------------------------
  # Param shaping and pre-validation (moved from facade)
  # ---------------------------

  @doc """
  Prepare attributes for creating an integration from UI params.
  """
  @spec prepare_attrs(%{String.t() => term()}, user_id()) ::
          {:ok,
           %{
             required(:user_id) => user_id(),
             required(:name) => String.t(),
             required(:provider) => String.t(),
             required(:base_url) => String.t(),
             required(:username) => String.t(),
             required(:password) => String.t(),
             required(:calendar_paths) => [String.t()],
             required(:provider_account_id) => String.t() | nil,
             required(:is_active) => boolean(),
             optional(:calendar_list) => [CalendarEntry.t()]
           }}
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

    # Derive provider_account_id for CalDAV-family dedup: base_url||username
    provider_account_id =
      if is_binary(base_url) and base_url != "" and is_binary(username) and username != "",
        do: "#{base_url}||#{username}",
        else: nil

    attrs = %{
      user_id: user_id,
      name: name,
      provider: provider,
      base_url: base_url,
      username: username,
      password: password,
      calendar_paths: calendar_paths_list,
      provider_account_id: provider_account_id,
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
    entry = calendar |> CalendarEntry.normalize() |> CalendarEntry.with_defaults()
    %{entry | selected: true}
  end

  defp ensure_calendar_list(attrs, calendar_paths_list) do
    case {Map.get(attrs, :calendar_list), calendar_paths_list} do
      {[_head | _tail], _paths} ->
        attrs

      {_empty, [_head | _tail] = paths} ->
        Map.put(attrs, :calendar_list, build_calendar_list_from_paths(paths))

      _no_paths ->
        attrs
    end
  end

  defp build_calendar_list_from_paths(paths) do
    Enum.map(paths, fn path ->
      %CalendarEntry{
        id: path,
        path: path,
        name: extract_calendar_name_from_path(path),
        selected: true
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

  `validate_config/1` is structural only (see
  `Tymeslot.Integrations.Calendar.Provider`); the live connectivity check that
  used to be embedded in some providers' `validate_config/1` now runs here
  explicitly, through the same rate-limited choke point
  (`Tymeslot.Integrations.Shared.ConnectionProbe`) the "Test connection" button
  uses, charged to the user submitting the form.
  """
  @spec prevalidate_config(%{required(:provider) => String.t(), optional(atom()) => term()}) ::
          {:ok, %{required(:provider) => String.t(), optional(atom()) => term()}}
          | {:error, %{discovery: String.t()} | {:rate_limited, String.t()} | :unattributable}
  def prevalidate_config(%{provider: provider} = attrs)
      when provider in @caldav_provider_strings do
    config = %{
      base_url: attrs[:base_url],
      username: attrs[:username],
      password: attrs[:password],
      calendar_paths: attrs[:calendar_paths] || [],
      provider: provider
    }

    with {:ok, provider_atom} <- ProviderRegistry.validate_provider(provider),
         {:ok, _provider_module} <- ProviderRegistry.get_provider(provider_atom) do
      case test_config(provider_atom, config, attrs[:user_id]) do
        :ok ->
          {:ok, attrs}

        # `ConnectionProbe`'s refusal is passed straight up, still tagged —
        # building copy for it is the web layer's job (see its moduledoc),
        # not this pre-validation step's.
        {:error, {:rate_limited, _message} = refusal} ->
          {:error, refusal}

        {:error, :unattributable} ->
          {:error, :unattributable}

        # Reported against `:discovery`, the key both CalDAV forms already use
        # for "the connection attempt itself failed". A probe failure is never
        # attributable to one input: the reason arrives as a sanitised sentence,
        # not a field, so it is shown form-level rather than guessed onto a
        # field from the wording of its message.
        {:error, reason} ->
          message = ErrorHandler.sanitize_error_message(reason, provider_atom)
          {:error, %{discovery: message}}
      end
    else
      # If provider validation/lookup fails, skip pre-validation and allow creation to proceed
      {:error, _error} -> {:ok, attrs}
    end
  end

  def prevalidate_config(attrs) when is_map(attrs) do
    # OAuth providers and any non-Caldav-like providers don't need pre-validation
    {:ok, attrs}
  end

  # Structural validation, then the live probe — charged to the user submitting
  # the form, through the same choke point (`Calendar.Connection.probe/3`) the
  # "Test connection" button uses.
  #
  # The structural check belongs HERE rather than inside `probe/3`: this is the
  # one path where `config` is untrusted user input. `probe/3`'s other callers
  # probe already-persisted integrations, which must not be re-validated against
  # current input rules (see `Connection.probe/3`). Validating first also means a
  # malformed submission is rejected without ever charging a rate-limit token.
  defp test_config(provider_atom, config, user_id) do
    with {:ok, provider_module} <- ProviderRegistry.get_provider(provider_atom),
         :ok <- provider_module.validate_config(config),
         {:ok, _message} <- Connection.probe(provider_atom, config, {:user, user_id}) do
      :ok
    end
  end
end
